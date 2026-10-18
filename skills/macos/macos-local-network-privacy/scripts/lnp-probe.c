/* TCP connect probe that reports its own responsible PID.
 * Built ad hoc (linker-signed, no bundle ID) on purpose: same identity class as
 * Homebrew/cargo/nix CLI binaries, so it cannot hold a Local Network grant. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
extern int responsibility_get_pid_responsible_for_pid(int);
int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s <ipv4> <port>\n", argv[0]); return 2; }
  struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(atoi(argv[2])) };
  if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) { fprintf(stderr, "bad ipv4\n"); return 2; }
  int s = socket(AF_INET, SOCK_STREAM, 0);
  int r = connect(s, (struct sockaddr *)&a, sizeof a);
  printf("pid %d resp %d connect %s\n", getpid(),
         responsibility_get_pid_responsible_for_pid(getpid()), r == 0 ? "ok" : strerror(errno));
  fflush(stdout);
  sleep(5); /* short-lived failures can suppress the LNP alert (FB16131937) */
  return r == 0 ? 0 : 1;
}
