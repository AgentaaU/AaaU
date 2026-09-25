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
  mutable last_cleanup_date : string;
}

let local_date time =
  let tm = Unix.localtime time in
  Printf.sprintf "%04d-%02d-%02d"
    (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let retention_days = 5

let oldest_kept_date now =
  let tm = Unix.localtime now in
  let start_of_today = { tm with Unix.tm_hour = 12; tm_min = 0; tm_sec = 0 } in
  let day = { start_of_today with Unix.tm_mday = tm.tm_mday - (retention_days - 1) } in
  local_date (fst (Unix.mktime day))

let audit_file_date name =
  if String.length name <> 21 ||
     String.sub name 0 6 <> "audit-" ||
     String.sub name 16 5 <> ".logl" ||
     name.[10] <> '-' || name.[13] <> '-' then None
  else
    let digit i = name.[i] >= '0' && name.[i] <= '9' in
    if List.for_all digit [6; 7; 8; 9; 11; 12; 14; 15] then
      let month = int_of_string (String.sub name 11 2) in
      let day = int_of_string (String.sub name 14 2) in
      if month >= 1 && month <= 12 && day >= 1 && day <= 31 then
        Some (String.sub name 6 10)
      else None
    else None

let cleanup_old_logs ~log_dir ~now =
  let cutoff = oldest_kept_date now in
  Sys.readdir log_dir |> Array.iter (fun name ->
    match audit_file_date name with
    | Some date when date < cutoff ->
        let path = Filename.concat log_dir name in
        (try
           if (Unix.lstat path).Unix.st_kind = Unix.S_REG then Unix.unlink path
         with Unix.Unix_error (error, _, _) ->
           Logs.warn (fun m -> m "Cannot remove old audit log %s: %s"
             path (Unix.error_message error)))
    | _ -> ())

let cleanup_with_warning t now =
  try cleanup_old_logs ~log_dir:t.log_dir ~now; true
  with Unix.Unix_error (error, _, _) ->
    Logs.warn (fun m -> m "Cannot scan audit log directory %s: %s"
      t.log_dir (Unix.error_message error));
    false

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
      let date = local_date (Unix.time ()) in
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
  else begin
    let* () =
      Lwt.catch
        (fun () -> flush_to_disk t)
        (fun e ->
          Logs_lwt.err (fun m -> m "Audit flush failed: %s" (Printexc.to_string e)))
    in
    let now = Unix.time () in
    let date = local_date now in
    if date <> t.last_cleanup_date then begin
      if cleanup_with_warning t now then t.last_cleanup_date <- date
    end;
    flush_loop t
  end

let create ~log_dir =
  let () =
    try Unix.mkdir log_dir 0o755 with Unix.Unix_error _ -> ()
  in
  let now = Unix.time () in
  let t = {
    log_dir;
    buffer = [];
    buffer_lock = Lwt_mutex.create ();
    closed = false;
    last_cleanup_date = "";
  } in
  if cleanup_with_warning t now then t.last_cleanup_date <- local_date now;
  Lwt.async (fun () -> flush_loop t);
  t

let flush t =
  flush_to_disk t

let close t =
  t.closed <- true;
  flush_to_disk t
