/* C stubs for PTY operations using Linux API */

#define _GNU_SOURCE  /* For posix_openpt */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>
#include <caml/unixsupport.h>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* TIOCGPTN - Get PTY Number */
#ifndef TIOCGPTN
#define TIOCGPTN _IOR('T', 0x30, unsigned int)
#endif

/* TIOCSPTLCK - Lock/unlock PTY */
#ifndef TIOCSPTLCK
#define TIOCSPTLCK _IOW('T', 0x31, int)
#endif

/* Open PTY master using posix_openpt */
CAMLprim value aaau_openpt(value v_flags)
{
    CAMLparam1(v_flags);
    int fd;
    int flags = Int_val(v_flags);
    
    fd = posix_openpt(flags);
    if (fd == -1) {
        uerror("posix_openpt", Nothing);
    }
    
    CAMLreturn(Val_int(fd));
}

/* Grant access to PTY slave */
CAMLprim value aaau_grantpt(value v_fd)
{
    CAMLparam1(v_fd);
    int fd = Int_val(v_fd);
    int ret;
    
    ret = grantpt(fd);
    if (ret == -1) {
        uerror("grantpt", Nothing);
    }
    
    CAMLreturn(Val_unit);
}

/* Unlock PTY master/slave pair */
CAMLprim value aaau_unlockpt(value v_fd)
{
    CAMLparam1(v_fd);
    int fd = Int_val(v_fd);
    int ret;
    
    ret = unlockpt(fd);
    if (ret == -1) {
        uerror("unlockpt", Nothing);
    }
    
    CAMLreturn(Val_unit);
}

/* Get PTY slave name using TIOCGPTN ioctl */
CAMLprim value aaau_ptsname(value v_fd)
{
    CAMLparam1(v_fd);
    CAMLlocal1(v_result);
    int fd = Int_val(v_fd);
    unsigned int pty_num;
    int ret;
    char pts_path[64];
    
    /* First, unlock the PTY */
    int unlock = 0;
    ret = ioctl(fd, TIOCSPTLCK, &unlock);
    if (ret == -1) {
        uerror("ioctl(TIOCSPTLCK)", Nothing);
    }
    
    /* Get the PTY number */
    ret = ioctl(fd, TIOCGPTN, &pty_num);
    if (ret == -1) {
        uerror("ioctl(TIOCGPTN)", Nothing);
    }
    
    /* Construct the slave path */
    snprintf(pts_path, sizeof(pts_path), "/dev/pts/%u", pty_num);
    
    v_result = caml_copy_string(pts_path);
    CAMLreturn(v_result);
}

/* Set terminal window size using TIOCSWINSZ */
#ifndef TIOCSWINSZ
#define TIOCSWINSZ 0x5414
#endif

CAMLprim value aaau_set_winsize(value v_fd, value v_rows, value v_cols)
{
    CAMLparam3(v_fd, v_rows, v_cols);
    int fd = Int_val(v_fd);
    struct winsize ws;
    int ret;
    
    ws.ws_row = (unsigned short)Int_val(v_rows);
    ws.ws_col = (unsigned short)Int_val(v_cols);
    ws.ws_xpixel = 0;
    ws.ws_ypixel = 0;
    
    ret = ioctl(fd, TIOCSWINSZ, &ws);
    if (ret == -1) {
        uerror("ioctl(TIOCSWINSZ)", Nothing);
    }
    
    CAMLreturn(Val_unit);
}

/* Set controlling terminal using TIOCSCTTY */
#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif

CAMLprim value aaau_set_ctty(value v_fd)
{
    CAMLparam1(v_fd);
    int fd = Int_val(v_fd);
    int ret;
    
    ret = ioctl(fd, TIOCSCTTY, 0);
    if (ret == -1) {
        uerror("ioctl(TIOCSCTTY)", Nothing);
    }
    
    CAMLreturn(Val_unit);
}

/* Get terminal window size using TIOCGWINSZ */
#ifndef TIOCGWINSZ
#define TIOCGWINSZ 0x5413
#endif

CAMLprim value aaau_get_winsize(value v_fd)
{
    CAMLparam1(v_fd);
    CAMLlocal1(v_result);
    int fd = Int_val(v_fd);
    struct winsize ws;
    int ret;
    
    ret = ioctl(fd, TIOCGWINSZ, &ws);
    if (ret == -1) {
        uerror("ioctl(TIOCGWINSZ)", Nothing);
    }
    
    /* Return a tuple (rows, cols) */
    v_result = caml_alloc_tuple(2);
    Store_field(v_result, 0, Val_int(ws.ws_row));
    Store_field(v_result, 1, Val_int(ws.ws_col));
    
    CAMLreturn(v_result);
}

/* Set foreground process group using tcsetpgrp */
CAMLprim value aaau_set_pgrp(value v_fd, value v_pid)
{
    CAMLparam2(v_fd, v_pid);
    int fd = Int_val(v_fd);
    pid_t pid = (pid_t)Int_val(v_pid);
    int ret;
    
    ret = tcsetpgrp(fd, pid);
    if (ret == -1) {
        uerror("tcsetpgrp", Nothing);
    }
    
    CAMLreturn(Val_unit);
}
