#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

struct aaau_peercred {
  uid_t uid;
  gid_t gid;
};

/* Return the kernel session of the peer process captured by SO_PEERCRED.
   The editor socket is Linux-only: UID authentication alone is insufficient
   because all agent sessions deliberately share one service account. */
CAMLprim value aaau_get_peer_session_id(value v_fd)
{
  CAMLparam1(v_fd);
#if defined(__linux__)
  int fd = Int_val(v_fd);
  struct ucred linux_cred;
  socklen_t cred_len = sizeof(linux_cred);

  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &linux_cred, &cred_len) == -1) {
    uerror("getsockopt", Nothing);
  }
  if (cred_len < sizeof(linux_cred)) {
    caml_failwith("getsockopt(SO_PEERCRED) returned a short credential struct");
  }
  pid_t sid = getsid(linux_cred.pid);
  if (sid == (pid_t)-1) {
    uerror("getsid", Nothing);
  }
  CAMLreturn(Val_int(sid));
#else
  caml_failwith("agent editor sockets require Linux SO_PEERCRED session IDs");
  CAMLreturn(Val_int(-1));
#endif
}

CAMLprim value aaau_get_peer_credentials(value v_fd)
{
  CAMLparam1(v_fd);
  CAMLlocal1(result);

  int fd = Int_val(v_fd);
  struct aaau_peercred cred;

#if defined(__linux__)
  struct ucred linux_cred;
  socklen_t cred_len = sizeof(linux_cred);

  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &linux_cred, &cred_len) == -1) {
    uerror("getsockopt", Nothing);
  }

  if (cred_len < sizeof(linux_cred)) {
    caml_failwith("getsockopt(SO_PEERCRED) returned a short credential struct");
  }

  cred.uid = linux_cred.uid;
  cred.gid = linux_cred.gid;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
  if (getpeereid(fd, &cred.uid, &cred.gid) == -1) {
    uerror("getpeereid", Nothing);
  }
#else
#error "Unsupported platform for peer credential lookup"
#endif

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(cred.uid));
  Store_field(result, 1, Val_int(cred.gid));
  CAMLreturn(result);
}
