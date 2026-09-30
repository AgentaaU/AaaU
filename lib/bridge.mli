(** Main bridge server *)

type t

val human_socket_mode : int
val editor_socket_mode : int
val human_peer_allowed : agent_uid:int -> Auth.user_info -> bool
val groups_are_isolated : agent_gid:int -> human_gid:int -> agent_username:string -> human_members:string array -> bool

val create :
  socket_path:string ->
  ?editor_socket_path:string ->
  shared_group:string ->
  agent_user:string ->
  log_dir:string ->
  ?default_program:string ->
  ?default_args:string list ->
  unit ->
  t
(** Create server configuration. 
    ~default_program: Program to run as agent (default: /bin/bash)
    ~default_args: Arguments for the program (default: ["-l"]) *)

val start : t -> unit Lwt.t
(** Start server, blocks until stopped *)

val stop : t -> unit Lwt.t
(** Stop server *)

(** {2 Unit-test hooks}

    The functions below expose the pieces of the handshake path that cannot be
    reached without root privileges (the real server must be able to switch to
    the agent account before it starts accepting connections). They are kept
    public so the socket and parser behaviour can be exercised directly. *)

val parse_new_json : string -> (string * string list * int * int, string) result
(** Parse a [NEW_JSON:] payload into program, arguments, rows and columns. *)

val new_json_defaults : t -> string -> string
(** Fill in the server's configured default program and arguments for a
    [NEW_JSON:] payload that omits both.  Payloads that already carry a
    [program] or [args] field are returned unchanged. *)

val requested_agent_user : t -> string -> (string, string) result
(** Resolve the agent account requested by a [NEW_JSON:] payload.  A missing
    [user] field falls back to the server's configured agent user.  An explicit
    account must exist, must not be root, and must be isolated from the human
    control group.  Only a root-run server may select an account other than the
    one it is already running as. *)

val authenticate_client :
  t -> Lwt_unix.file_descr -> (Auth.user_info, string) result Lwt.t
(** Resolve the peer of a connected human socket. *)

val handle_handshake :
  t ->
  Lwt_unix.file_descr ->
  Auth.user_info ->
  ( [ `Dedicated of unit Lwt.t
    | `Existing of Session.t * string
    | `New of Session.t * string ],
    string )
  result
  Lwt.t
(** Read and act on a single handshake line from [client_fd]. *)

val handle_client : t -> Lwt_unix.file_descr -> string -> unit Lwt.t
(** Serve one authenticated human connection until it disconnects. *)

val handle_editor_client : t -> Lwt_unix.file_descr -> unit Lwt.t
(** Serve one connection on the isolated agent editor socket. *)

val register_session : t -> Session.t -> unit Lwt.t
(** Add an already-created session to the server's routing table. *)

val set_running : t -> bool -> unit
(** Toggle the accept/serve flag.  Only useful for unit tests that drive
    the connection handlers without calling {!start}. *)

val cleanup_dead_sessions : t -> unit Lwt.t
(** Remove sessions whose agent has exited and that have no clients left.
    One pass of the periodic cleanup loop, exposed for tests. *)
