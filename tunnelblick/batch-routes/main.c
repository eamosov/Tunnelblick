/*
 *  batch-routes.c
 *
 *  Reads OpenVPN route environment variables (route_network_N, route_netmask_N,
 *  route_gateway_N) and adds all routes at once via a PF_ROUTE socket,
 *  avoiding the overhead of thousands of fork+exec calls to /sbin/route.
 *
 *  Usage: batch-routes
 *    (invoked from Tunnelblick's up script with OpenVPN env vars inherited)
 *
 *  Copyright © 2026 Tunnelblick contributors. All rights reserved.
 *  Licensed under the GNU General Public License version 2.
 */

#include <sys/types.h>
#include <sys/socket.h>
#include <net/route.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

/*
 * Fill a sockaddr_in into buf, return the aligned length.
 * macOS routing socket requires sockaddr to be aligned to 4 bytes.
 */
static int
fill_sockaddr_in(void *buf, struct in_addr addr)
{
    struct sockaddr_in *sin = (struct sockaddr_in *)buf;
    memset(sin, 0, sizeof(*sin));
    sin->sin_len    = sizeof(*sin);
    sin->sin_family = AF_INET;
    sin->sin_addr   = addr;
    return (int)((sizeof(*sin) + 3) & ~3);
}

/*
 * Add a single IPv4 route via the PF_ROUTE socket.
 * Returns 0 on success, -1 on error.
 */
static int
add_route(int sock, struct in_addr dst, struct in_addr mask, struct in_addr gw, int seq)
{
    char              buf[512];
    struct rt_msghdr *rtm = (struct rt_msghdr *)buf;
    char             *cp;
    int               len;

    memset(buf, 0, sizeof(buf));

    rtm->rtm_type    = RTM_ADD;
    rtm->rtm_flags   = RTF_UP | RTF_GATEWAY | RTF_STATIC;
    rtm->rtm_version = RTM_VERSION;
    rtm->rtm_seq     = seq;
    rtm->rtm_addrs   = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    rtm->rtm_pid     = getpid();

    cp = buf + sizeof(struct rt_msghdr);

    /* RTA_DST */
    len = fill_sockaddr_in(cp, dst);
    cp += len;

    /* RTA_GATEWAY */
    len = fill_sockaddr_in(cp, gw);
    cp += len;

    /* RTA_NETMASK */
    len = fill_sockaddr_in(cp, mask);
    cp += len;

    rtm->rtm_msglen = (int)(cp - buf);

    if (write(sock, buf, rtm->rtm_msglen) < 0) {
        if (errno == EEXIST)
            return 0;
        return -1;
    }

    return 0;
}

/*
 * Delete a single IPv4 route via the PF_ROUTE socket.
 * Returns 0 on success, -1 on error.
 */
static int
delete_route(int sock, struct in_addr dst, struct in_addr mask, struct in_addr gw, int seq)
{
    char              buf[512];
    struct rt_msghdr *rtm = (struct rt_msghdr *)buf;
    char             *cp;
    int               len;

    memset(buf, 0, sizeof(buf));

    rtm->rtm_type    = RTM_DELETE;
    rtm->rtm_flags   = RTF_UP | RTF_GATEWAY | RTF_STATIC;
    rtm->rtm_version = RTM_VERSION;
    rtm->rtm_seq     = seq;
    rtm->rtm_addrs   = RTA_DST | RTA_GATEWAY | RTA_NETMASK;
    rtm->rtm_pid     = getpid();

    cp = buf + sizeof(struct rt_msghdr);

    len = fill_sockaddr_in(cp, dst);
    cp += len;

    len = fill_sockaddr_in(cp, gw);
    cp += len;

    len = fill_sockaddr_in(cp, mask);
    cp += len;

    rtm->rtm_msglen = (int)(cp - buf);

    if (write(sock, buf, rtm->rtm_msglen) < 0) {
        if (errno == ESRCH)
            return 0; /* route not found — not an error for delete */
        return -1;
    }

    return 0;
}

static void
usage(void)
{
    fprintf(stderr, "Usage: batch-routes [add|delete]\n"
                    "  Reads route_network_N, route_netmask_N, route_gateway_N\n"
                    "  environment variables set by OpenVPN (with --route-noexec).\n"
                    "  Default action is 'add'.\n");
}

int
main(int argc, char *argv[])
{
    int do_delete = 0;

    if (argc > 1) {
        if (strcmp(argv[1], "delete") == 0) {
            do_delete = 1;
        } else if (strcmp(argv[1], "add") == 0) {
            do_delete = 0;
        } else {
            usage();
            return 1;
        }
    }

    const char *vpn_gw_str = getenv("route_vpn_gateway");
    struct in_addr vpn_gw;

    if (vpn_gw_str != NULL) {
        inet_aton(vpn_gw_str, &vpn_gw);
    } else {
        memset(&vpn_gw, 0, sizeof(vpn_gw));
    }

    /* Count routes */
    int route_count = 0;
    for (int i = 1; ; i++) {
        char var_name[64];
        snprintf(var_name, sizeof(var_name), "route_network_%d", i);
        if (getenv(var_name) == NULL)
            break;
        route_count++;
    }

    if (route_count == 0) {
        fprintf(stderr, "batch-routes: no routes found in environment\n");
        return 0;
    }

    const char *action = do_delete ? "deleting" : "adding";
    fprintf(stderr, "batch-routes: %s %d routes via PF_ROUTE socket\n", action, route_count);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int sock = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (sock < 0) {
        fprintf(stderr, "batch-routes: socket(PF_ROUTE): %s\n", strerror(errno));
        return 1;
    }

    /* Disable reading replies — we only write */
    int off = 0;
    setsockopt(sock, SOL_SOCKET, SO_USELOOPBACK, &off, sizeof(off));
    shutdown(sock, SHUT_RD);

    int ok     = 0;
    int failed = 0;

    for (int i = 1; i <= route_count; i++) {
        char net_var[64], mask_var[64], gw_var[64];
        snprintf(net_var,  sizeof(net_var),  "route_network_%d", i);
        snprintf(mask_var, sizeof(mask_var), "route_netmask_%d", i);
        snprintf(gw_var,   sizeof(gw_var),   "route_gateway_%d", i);

        const char *net_str  = getenv(net_var);
        const char *mask_str = getenv(mask_var);
        const char *gw_str   = getenv(gw_var);

        if (net_str == NULL)
            break;

        struct in_addr dst, mask, gw;

        if (!inet_aton(net_str, &dst)) {
            fprintf(stderr, "batch-routes: invalid network '%s' for route %d\n", net_str, i);
            failed++;
            continue;
        }

        if (mask_str != NULL && strlen(mask_str) > 0) {
            if (!inet_aton(mask_str, &mask))
                mask.s_addr = htonl(0xFFFFFFFF);
        } else {
            mask.s_addr = htonl(0xFFFFFFFF);
        }

        if (gw_str != NULL && strlen(gw_str) > 0) {
            if (!inet_aton(gw_str, &gw))
                gw = vpn_gw;
        } else {
            gw = vpn_gw;
        }

        int rc;
        if (do_delete)
            rc = delete_route(sock, dst, mask, gw, i);
        else
            rc = add_route(sock, dst, mask, gw, i);

        if (rc == 0) {
            ok++;
        } else {
            fprintf(stderr, "batch-routes: failed to %s route %s/%s via %s: %s\n",
                    do_delete ? "delete" : "add",
                    net_str,
                    mask_str ? mask_str : "32",
                    gw_str ? gw_str : (vpn_gw_str ? vpn_gw_str : "unknown"),
                    strerror(errno));
            failed++;
        }
    }

    close(sock);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;

    fprintf(stderr, "batch-routes: done — %d %s, %d failed, %.3f seconds\n",
            ok, do_delete ? "deleted" : "added", failed, elapsed);

    return (failed > 0) ? 1 : 0;
}
