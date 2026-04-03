(** Audit log implementation *)

open Lwt.Syntax

type record = {
  timestamp : float;
  source : string;
  user : string;
  session_id : string;
  command_type : string;
  content : string;
  metadata : (string * string) list;
}

type t = {
  log_dir : string;
  mutable buffer : record list;
  buffer_lock : Lwt_mutex.t;
  flush_cond : unit Lwt_condition.t;
}

let create ~log_dir =
  let () =
    try Unix.mkdir log_dir 0o755 with Unix.Unix_error _ -> ()
  in
  {
    log_dir;
    buffer = [];
    buffer_lock = Lwt_mutex.create ();
    flush_cond = Lwt_condition.create ();
  }

let record_to_json r : Yojson.Safe.t =
  `Assoc [
    "timestamp", `Float r.timestamp;
    "source", `String r.source;
    "user", `String r.user;
    "session_id", `String r.session_id;
    "command_type", `String r.command_type;
    "content", `String r.content;
    "metadata", `Assoc (List.map (fun (k, v) -> (k, `String v)) r.metadata);
  ]

let log t record =
  Lwt_mutex.with_lock t.buffer_lock (fun () ->
    t.buffer <- record :: t.buffer;
    Lwt.return_unit
  )

let flush_to_disk t =
  let* records = Lwt_mutex.with_lock t.buffer_lock (fun () ->
    let records = List.rev t.buffer in
    t.buffer <- [];
    Lwt.return records
  ) in
  let* () =
    if List.length records = 0 then
      Lwt.return_unit
    else
      let time = Unix.time () in
      let tm = Unix.localtime time in
      let date = Printf.sprintf "%04d-%02d-%02d"
        (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday in
      let log_file = Filename.concat t.log_dir ("audit-" ^ date ^ ".logl") in
      let lines =
        List.map (fun r -> Yojson.Safe.to_string (record_to_json r)) records
      in
      let content = String.concat "\n" lines ^ "\n" in
      let flags = [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND] in
      let* fd = Lwt_unix.openfile log_file flags 0o644 in
      let oc = Lwt_io.of_fd ~mode:Lwt_io.output fd in
      let* () = Lwt_io.write oc content in
      Lwt_io.close oc
  in
  Lwt.return_unit

let flush t =
  Lwt_condition.signal t.flush_cond ();
  flush_to_disk t

let close t =
  flush_to_disk t
