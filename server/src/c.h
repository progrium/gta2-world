/* No _GNU_SOURCE: it turns sockaddr args into transparent unions. */
#include <ngtcp2/ngtcp2.h>
#include <ngtcp2/ngtcp2_crypto.h>
#include <ngtcp2/ngtcp2_crypto_gnutls.h>
#include <nghttp3/nghttp3.h>
#include <gnutls/gnutls.h>
#include <gnutls/crypto.h>
#include <gnutls/x509.h>
#include <sys/socket.h>
#include <sys/random.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <string.h>
#include <signal.h>
int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags);
#include <sys/stat.h>
#include <dirent.h>
#include <stdlib.h>
#include <stdio.h>
