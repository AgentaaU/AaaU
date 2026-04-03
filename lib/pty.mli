(** PTY (Pseudo Terminal) operations interface *)

type t
(** PTY master file descriptor wrapper *)

type slave = private string
(** PTY slave device path *)

val open_pty : unit -> (t * slave, string) result
(** Open a new PTY master/slave pair *)

val set_raw_mode : Unix.file_descr -> unit
(** Set raw terminal mode on caller's terminal *)

val set_terminal_size : Unix.file_descr -> rows:int -> cols:int -> unit
(** Set terminal window size (TIOCSWINSZ) *)

val get_terminal_size : Unix.file_descr -> (int * int)
(** Get terminal window size (TIOCGWINSZ), returns (rows, cols) *)

val set_controlling_terminal : Unix.file_descr -> unit
(** Set the file descriptor as the controlling terminal (TIOCSCTTY) *)

val login_shell_argv : program:string -> args:string list -> string array
(** Build a login-shell argv that preserves user argv without shell re-parsing *)

val fork_agent :
  slave:slave ->
  user:string ->
  program:string ->
  args:string list ->
  env:(string * string) list ->
  rows:int ->
  cols:int ->
  (int, string) result
(**
  Fork child process, switch to specified user, execute program in PTY slave.
  Returns child process PID. Terminal size is set to rows x cols.
*)

val read : t -> bytes -> int -> int -> int Lwt.t
(** Read data from PTY master *)

val write : t -> bytes -> int -> int -> int Lwt.t
(** Write data to PTY master *)

val close : t -> unit Lwt.t
(** Close PTY master *)

val fd : t -> Unix.file_descr
(** Get underlying file descriptor (for select/poll) *)

val get_slave_path : t -> slave
(** Get slave path *)
