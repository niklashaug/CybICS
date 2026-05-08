#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define BUFFER_SIZE 8192

static int parse_port(const char *value) {
    char *end = NULL;
    long port = strtol(value, &end, 10);
    if (*value == '\0' || *end != '\0' || port < 1 || port > 65535) {
        return -1;
    }
    return (int)port;
}

static int connect_upstream(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);

    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

static int listen_socket(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    int enabled = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);

    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        close(fd);
        return -1;
    }

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }

    if (listen(fd, 16) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

static int copy_bytes(int from_fd, int to_fd) {
    char buffer[BUFFER_SIZE];
    ssize_t count = recv(from_fd, buffer, sizeof(buffer), 0);
    if (count <= 0) {
        return -1;
    }

    ssize_t written = 0;
    while (written < count) {
        ssize_t rc = send(to_fd, buffer + written, (size_t)(count - written), 0);
        if (rc <= 0) {
            return -1;
        }
        written += rc;
    }

    return 0;
}

static void relay(int client_fd, const char *upstream_host, int upstream_port) {
    int upstream_fd = connect_upstream(upstream_host, upstream_port);
    if (upstream_fd < 0) {
        close(client_fd);
        return;
    }

    for (;;) {
        fd_set read_fds;
        FD_ZERO(&read_fds);
        FD_SET(client_fd, &read_fds);
        FD_SET(upstream_fd, &read_fds);

        int max_fd = client_fd > upstream_fd ? client_fd : upstream_fd;
        int ready = select(max_fd + 1, &read_fds, NULL, NULL, NULL);
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }

        if (FD_ISSET(client_fd, &read_fds) && copy_bytes(client_fd, upstream_fd) < 0) {
            break;
        }

        if (FD_ISSET(upstream_fd, &read_fds) && copy_bytes(upstream_fd, client_fd) < 0) {
            break;
        }
    }

    close(upstream_fd);
    close(client_fd);
}

int main(int argc, char **argv) {
    if (argc != 5) {
        fprintf(stderr, "usage: %s <listen-ip> <listen-port> <upstream-ip> <upstream-port>\n", argv[0]);
        return 2;
    }

    int listen_port = parse_port(argv[2]);
    int upstream_port = parse_port(argv[4]);
    if (listen_port < 0 || upstream_port < 0) {
        fprintf(stderr, "invalid port\n");
        return 2;
    }

    signal(SIGCHLD, SIG_IGN);

    int server_fd = listen_socket(argv[1], listen_port);
    if (server_fd < 0) {
        perror("listen");
        return 1;
    }

    for (;;) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            perror("accept");
            continue;
        }

        pid_t child = fork();
        if (child == 0) {
            close(server_fd);
            relay(client_fd, argv[3], upstream_port);
            return 0;
        }

        close(client_fd);
    }
}
