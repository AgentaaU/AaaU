(** Main bridge server *)

type t

val create :
  socket_path:string ->
  shared_group:string ->
  admin_group:string ->
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
