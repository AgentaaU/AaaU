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
