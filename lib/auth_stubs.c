#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/unixsupport.h>

#include <sys/socket.h>
#include <sys/types.h>

struct aaau_peercred {
  pid_t pid;
  uid_t uid;
  gid_t gid;
};

CAMLprim value aaau_get_peer_credentials(value v_fd)
{
  CAMLparam1(v_fd);
  CAMLlocal1(result);

  int fd = Int_val(v_fd);
  struct aaau_peercred cred;
  socklen_t cred_len = sizeof(cred);

  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) == -1) {
    uerror("getsockopt", Nothing);
  }

  if (cred_len < sizeof(cred)) {
    caml_failwith("getsockopt(SO_PEERCRED) returned a short credential struct");
  }

  result = caml_alloc_tuple(2);
  Store_field(result, 0, Val_int(cred.uid));
  Store_field(result, 1, Val_int(cred.gid));
  CAMLreturn(result);
}
