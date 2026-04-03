(** PTY operations implementation using Linux API *)

(* External C bindings *)
external openpt : int -> int = "aaau_openpt"
external grantpt : int -> unit = "aaau_grantpt"
external unlockpt : int -> unit = "aaau_unlockpt"
external ptsname : int -> string = "aaau_ptsname"
external set_winsize : int -> int -> int -> unit = "aaau_set_winsize"
external get_winsize : int -> (int * int) = "aaau_get_winsize"
external set_ctty : int -> unit = "aaau_set_ctty"
external set_pgrp : int -> int -> unit = "aaau_set_pgrp"

type t = {
  master_fd : Unix.file_descr;
  slave_path : string;
  mutable lwt_fd : Lwt_unix.file_descr option;
}

type slave = string

let get_slave_path pty = pty.slave_path
let fd pty = pty.master_fd

(* Convert file_descr to int for C bindings *)
let fd_to_int fd = (Obj.magic fd : int)
let int_to_fd i = (Obj.magic i : Unix.file_descr)

(* Open PTY using Linux API *)
let open_pty () =
  try
    (* Open master PTY using posix_openpt *)
    let flags = 0x02 lor 0x100 in (* O_RDWR | O_NOCTTY *)
    let master_int = openpt flags in
    let master_fd = int_to_fd master_int in

    (* Grant access to slave *)
    grantpt master_int;

    (* Unlock PTY *)
    unlockpt master_int;

    (* Get slave device path *)
    let slave = ptsname master_int in

    (* Validate the slave path *)
    if not (String.starts_with ~prefix:"/dev/pts/" slave) then
      Error (Printf.sprintf "Invalid slave device path: %s" slave)
    else begin
      (* Change permissions of slave device so agent user can access it *)
      let _ = Sys.command (Printf.sprintf "chmod 666 %s 2>/dev/null || true" slave) in
      
      (* Set master fd to non-blocking mode for Lwt *)
      Unix.set_nonblock master_fd;
      
      Ok ({ master_fd; slave_path = slave; lwt_fd = None }, slave)
    end
  with
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "Unix error in %s(%s): %s" fn arg (Unix.error_message err))
  | Failure msg ->
    Error (Printf.sprintf "PTY error: %s" msg)
  | e -> Error (Printexc.to_string e)

(* Set raw mode on caller's terminal *)
let set_raw_mode fd =
  let attr = Unix.tcgetattr fd in
  let new_attr = {
    attr with
    c_ignbrk = false;
    c_brkint = false;
    c_ignpar = false;
    c_parmrk = false;
    c_inpck = false;
    c_istrip = false;
    c_inlcr = false;
    c_igncr = false;
    c_icrnl = false;
    c_ixon = false;
    c_ixoff = false;
    c_opost = false;
    c_isig = false;
    c_icanon = false;
    c_echo = false;
    c_echoe = false;
    c_echok = false;
    c_echonl = false;
    c_vmin = 1;
    c_vtime = 0;
  } in
  Unix.tcsetattr fd Unix.TCSANOW new_attr

(* Set terminal size using ioctl *)
let set_terminal_size fd ~rows ~cols =
  try
    let fd_int = fd_to_int fd in
    set_winsize fd_int rows cols
  with _ -> ()

(* Get terminal size *)
let get_terminal_size fd =
  try
    let fd_int = fd_to_int fd in
    get_winsize fd_int
  with _ -> (24, 80)

(* Set controlling terminal *)
let set_controlling_terminal fd =
  try
    let fd_int = fd_to_int fd in
    set_ctty fd_int
  with _ -> ()  (* Default fallback *)

(* Set foreground process group *)
let set_foreground_process_group fd pid =
  try
    let fd_int = fd_to_int fd in
    set_pgrp fd_int pid
  with _ -> ()  (* Default fallback *)

let login_shell_argv ~program ~args =
  Array.of_list
    ("/bin/bash" :: "-i" :: "-l" :: "-c" :: "exec \"$@\"" :: "--" :: program :: args)

(* Configure PTY slave for interactive use *)
let configure_slave fd =
  try
    let attr = Unix.tcgetattr fd in
    let new_attr = {
      attr with
      (* Input modes: enable CR->NL, enable signal chars *)
      c_ignbrk = false;
      c_brkint = true;    (* Generate SIGINT on break *)
      c_ignpar = false;
      c_parmrk = false;
      c_inpck = false;
      c_istrip = false;
      c_inlcr = false;
      c_igncr = false;
      c_icrnl = true;     (* Convert CR to NL *)
      c_ixon = true;      (* Enable XON/XOFF *)
      c_ixoff = false;
      (* Output modes: enable processing *)
      c_opost = true;
      (* Local modes: non-canonical with signals *)
      c_isig = true;      (* Enable signal chars like Ctrl-C *)
      c_icanon = false;   (* Non-canonical for interactive apps *)
      c_echo = true;      (* Enable echo *)
      c_echoe = true;     (* Echo erase character as backspace *)
      c_echok = true;     (* Echo NL after kill *)
      c_echonl = false;
      (* Blocking read *)
      c_vmin = 1;
      c_vtime = 0;
    } in
    Unix.tcsetattr fd Unix.TCSANOW new_attr
  with _ -> ()

(* Fork and switch to user *)
let fork_agent ~slave ~user ~program ~args ~env ~rows ~cols =
  try
    (* Check absolute paths only - relative commands will be resolved by login shell *)
    if String.starts_with ~prefix:"/" program then begin
      if not (Sys.file_exists program) then
        raise (Failure (Printf.sprintf "Program not found: %s" program));
      (* Check if executable using Unix.access *)
      try Unix.access program [Unix.X_OK]
      with Unix.Unix_error _ ->
        raise (Failure (Printf.sprintf "Program not executable: %s" program))
    end;
    
    let slave_fd = Unix.openfile slave [Unix.O_RDWR] 0 in

    (* Set terminal size before fork *)
    set_terminal_size slave_fd ~rows ~cols;

    let pid = Unix.fork () in

    if pid = 0 then begin
      (* Child process *)
      try
        (* Create new session - this detaches from current controlling terminal *)
        let _ = Unix.setsid () in

        (* Open slave as controlling terminal *)
        let slave_ctl = Unix.openfile slave [Unix.O_RDWR] 0 in
        
        (* Set the slave as the controlling terminal for this session *)
        set_controlling_terminal slave_ctl;

        (* Set foreground process group so signals are delivered correctly *)
        set_foreground_process_group slave_ctl (Unix.getpid ());

        (* Configure PTY slave for interactive use *)
        configure_slave slave_ctl;

        (* Duplicate to standard IO *)
        Unix.dup2 slave_ctl Unix.stdin;
        Unix.dup2 slave_ctl Unix.stdout;
        Unix.dup2 slave_ctl Unix.stderr;

        (* Close the original slave_ctl since it's now stdin/stdout/stderr *)
        Unix.close slave_ctl;
        
        (* Close the PTY master fd in child *)
        Unix.close slave_fd;

        (* Get user information *)
        let user_entry = Unix.getpwnam user in
        let group_entry = Unix.getgrnam user in

        (* Initialize group list and switch *)
        let gid = group_entry.Unix.gr_gid in
        let uid = user_entry.Unix.pw_uid in

        (* Clear supplementary groups *)
        let _ = Unix.setgroups [||] in
        
        (* Switch to agent user *)
        Unix.setgid gid;
        Unix.setuid uid;

        (* Set environment *)
        List.iter (fun (k, v) -> Unix.putenv k v) env;
        Unix.putenv "HOME" user_entry.Unix.pw_dir;
        Unix.putenv "USER" user;

        (* Change directory *)
        Unix.chdir user_entry.Unix.pw_dir;

        (* Preserve login-shell environment without re-parsing user argv. *)
        let argv = login_shell_argv ~program ~args in
        Unix.execvp "/bin/bash" argv

      with e ->
        Printf.eprintf "Agent startup failed: %s\n%!" (Printexc.to_string e);
        Unix._exit 1
    end else begin
      (* Parent process *)
      Unix.close slave_fd;
      Ok pid
    end

  with
  | Unix.Unix_error (err, fn, arg) ->
    Error (Printf.sprintf "Fork error in %s(%s): %s" fn arg (Unix.error_message err))
  | Failure msg ->
    Error msg
  | e -> Error (Printf.sprintf "Fork error: %s" (Printexc.to_string e))

(* Get or create Lwt file descriptor.
   Master FD is already in non-blocking mode (set in open_pty),
   so we use ~set_flags:false to preserve it and avoid worker thread pool. *)
let get_lwt_fd pty =
  match pty.lwt_fd with
  | Some fd -> fd
  | None ->
      let fd = Lwt_unix.of_unix_file_descr ~set_flags:false pty.master_fd in
      pty.lwt_fd <- Some fd;
      fd

(* Lwt wrapper *)
let read pty buf off len =
  Lwt_unix.read (get_lwt_fd pty) buf off len

let write pty buf off len =
  Lwt_unix.write (get_lwt_fd pty) buf off len

let close pty =
  match pty.lwt_fd with
  | Some fd ->
      (* Mark as closed by setting lwt_fd to None *)
      pty.lwt_fd <- None;
      Lwt_unix.close fd
  | None ->
      (* Already closed or not opened as Lwt fd, close master_fd via Lwt *)
      let lwt_fd = Lwt_unix.of_unix_file_descr ~set_flags:false pty.master_fd in
      Lwt_unix.close lwt_fd
