type source = { fd : Unix.file_descr; stat : Unix.LargeFile.stats; mutable closed : bool }
type temporary = { path : string; owner_uid : int; mutable cleaned : bool }

external open_nofollow_rw : string -> Unix.file_descr = "aaau_open_nofollow_rw"
external open_nofollow_ro : string -> Unix.file_descr = "aaau_open_nofollow_ro"
external create_exclusive : string -> int -> Unix.file_descr = "aaau_create_exclusive"

let close_noerr fd = try Unix.close fd with _ -> ()
let unlink_noerr path = try Unix.unlink path with _ -> ()

let read_fd fd =
  let stat = Unix.LargeFile.fstat fd in
  if stat.Unix.LargeFile.st_kind <> Unix.S_REG then Error "Editor buffer must be a regular file"
  else if stat.Unix.LargeFile.st_size > Int64.of_int Editor_protocol.max_buffer_size then Error "Editor buffer exceeds size limit"
  else
    try
      ignore (Unix.LargeFile.lseek fd 0L Unix.SEEK_SET);
      let length = Int64.to_int stat.Unix.LargeFile.st_size in
      let data = Bytes.create length in
      let rec loop offset =
        if offset < length then
          let count = Unix.read fd data offset (length - offset) in
          if count = 0 then raise End_of_file else loop (offset + count)
      in
      loop 0; Ok (Bytes.unsafe_to_string data)
    with exn -> Error (Printexc.to_string exn)

let open_source ~path ~owner_uid =
  if path = "" || String.contains path '\000' || String.starts_with ~prefix:"-" path then
    Error "Exactly one filename (not an option) is required"
  else
    try
      let fd = open_nofollow_rw path in
      let stat = Unix.LargeFile.fstat fd in
      if stat.Unix.LargeFile.st_kind <> Unix.S_REG then begin close_noerr fd; Error "Editor buffer must be a regular file" end
      else if stat.Unix.LargeFile.st_uid <> owner_uid then begin close_noerr fd; Error "Editor buffer must be owned by the agent" end
      else if stat.Unix.LargeFile.st_size > Int64.of_int Editor_protocol.max_buffer_size then begin close_noerr fd; Error "Editor buffer exceeds size limit" end
      else Ok { fd; stat; closed = false }
    with exn -> Error (Printexc.to_string exn)

let read_source source = if source.closed then Error "Editor buffer is closed" else read_fd source.fd

let write_all fd data =
  let rec loop offset =
    if offset < String.length data then
      let count = Unix.write_substring fd data offset (String.length data - offset) in
      if count = 0 then raise End_of_file else loop (offset + count)
  in loop 0

let write_source source content =
  if source.closed then Error "Editor buffer is closed"
  else if String.length content > Editor_protocol.max_buffer_size then Error "Edited buffer exceeds size limit"
  else
    try
      let current = Unix.LargeFile.fstat source.fd in
      if current.Unix.LargeFile.st_dev <> source.stat.Unix.LargeFile.st_dev
         || current.Unix.LargeFile.st_ino <> source.stat.Unix.LargeFile.st_ino
         || current.Unix.LargeFile.st_kind <> Unix.S_REG then
        Error "Editor buffer identity changed"
      else begin
        (* A provider success must not turn a local I/O error into a silently
           truncated prompt. Keep a bounded rollback copy before modifying the
           already-validated inode. *)
        match read_fd source.fd with
        | Error message -> Error message
        | Ok original ->
          let replace value =
            Unix.LargeFile.ftruncate source.fd 0L;
            ignore (Unix.LargeFile.lseek source.fd 0L Unix.SEEK_SET);
            write_all source.fd value;
            Unix.fsync source.fd
          in
          begin try
            replace content;
            Ok ()
          with exn ->
            let failure = Printexc.to_string exn in
            begin try replace original with _ -> () end;
            Error ("Failed to copy edited buffer; original content was restored when possible: " ^ failure)
          end
      end
    with exn -> Error (Printexc.to_string exn)

let apply_response source (response : Editor_protocol.response) =
  if response.status <> 0 then response.status, response.error
  else match response.content with
    | None -> 74, Some "Editor provider returned no edited buffer"
    | Some edited ->
      begin match write_source source edited with
      | Ok () -> 0, None
      | Error message -> 74, Some message
      end

let close_source source = if not source.closed then begin source.closed <- true; close_noerr source.fd end

let create_temporary ~content =
  if String.length content > Editor_protocol.max_buffer_size then Error "Editor buffer exceeds size limit"
  else
    let rec attempt remaining =
      if remaining = 0 then Error "Could not allocate a unique editor temporary file"
      else
        let random = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
        let path = Filename.concat "/tmp" ("aaau-editor-" ^ random) in
        try
          let fd = create_exclusive path 0o600 in
          try
            Unix.fchmod fd 0o600;
            write_all fd content;
            Unix.fsync fd;
            close_noerr fd;
            Ok { path; owner_uid = Unix.getuid (); cleaned = false }
          with exn -> close_noerr fd; unlink_noerr path; Error (Printexc.to_string exn)
        with Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (remaining - 1)
           | exn -> Error (Printexc.to_string exn)
    in attempt 10

let temporary_path temporary = temporary.path

let read_temporary temporary =
  if temporary.cleaned then Error "Editor temporary file is unavailable"
  else
    try
      let fd = open_nofollow_ro temporary.path in
      let stat = Unix.LargeFile.fstat fd in
      let valid = stat.Unix.LargeFile.st_kind = Unix.S_REG
                  && stat.Unix.LargeFile.st_uid = temporary.owner_uid
                  && stat.Unix.LargeFile.st_perm land 0o077 = 0 in
      if not valid then begin close_noerr fd; Error "Editor temporary ownership or permissions changed" end
      else let result = read_fd fd in close_noerr fd; result
    with exn -> Error (Printexc.to_string exn)

let cleanup_temporary temporary =
  if not temporary.cleaned then begin temporary.cleaned <- true; unlink_noerr temporary.path end
