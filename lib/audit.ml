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
  mutable closed : bool;
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
    if records = [] then
      Lwt.return_unit
    else begin
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
      let* fd = Lwt_unix.openfile log_file flags 0o600 in
      let oc = Lwt_io.of_fd ~mode:Lwt_io.output fd in
      let* () = Lwt.finalize
        (fun () -> Lwt_io.write oc content)
        (fun () -> Lwt_io.close oc) in
      (* Only discard records after a complete successful write. *)
      t.buffer <- [];
      Lwt.return_unit
    end
  ) in
  Lwt.return records

let rec flush_loop t =
  let* () = Lwt_unix.sleep 5.0 in
  if t.closed then
    Lwt.return_unit
  else
    let* () =
      Lwt.catch
        (fun () -> flush_to_disk t)
        (fun e ->
          Logs_lwt.err (fun m -> m "Audit flush failed: %s" (Printexc.to_string e)))
    in
    flush_loop t

let create ~log_dir =
  let () =
    try Unix.mkdir log_dir 0o755 with Unix.Unix_error _ -> ()
  in
  let t = {
    log_dir;
    buffer = [];
    buffer_lock = Lwt_mutex.create ();
    closed = false;
  } in
  Lwt.async (fun () -> flush_loop t);
  t

let flush t =
  flush_to_disk t

let close t =
  t.closed <- true;
  flush_to_disk t
