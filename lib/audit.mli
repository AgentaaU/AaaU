(** Audit log system *)

type record = {
  timestamp : float;
  source : string;           (** "human", "agent", "system" *)
  user : string;
  session_id : string;
  command_type : string;     (** "input", "output", "control", "session_start" *)
  content : string;
  metadata : (string * string) list;
}

type t

val create : log_dir:string -> t
(** Create audit logger *)

val log : t -> record -> unit Lwt.t
(** Record a log entry *)

val flush : t -> unit Lwt.t
(** Force flush to disk *)

val close : t -> unit Lwt.t
(** Close log *)
