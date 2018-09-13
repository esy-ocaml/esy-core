module Record = struct

  module Opam = struct
    type t = {
      name : Package.Opam.OpamName.t;
      version : Package.Opam.OpamPackageVersion.t;
      opam : Package.Opam.OpamFile.t;
      override : Package.OpamOverride.t option;
    } [@@deriving yojson]
  end

  module SourceWithMirrors = struct
    type t = Source.t * Source.t list

    let to_yojson = function
      | main, [] -> Source.to_yojson main
      | main, mirrors -> `List (List.map ~f:Source.to_yojson (main::mirrors))

    let of_yojson (json : Json.t) =
      let open Result.Syntax in
      match json with
      | `String _ | `Assoc _ ->
        let%bind source = Source.of_yojson json in
        return (source, [])
      | `List _ ->
        begin match%bind Json.Decode.list Source.of_yojson json with
        | main::mirrors -> return (main, mirrors)
        | [] -> error "expected a non empty array or a string"
        end
      | _ -> error "expected a non empty array or a string"

  end

  type t = {
    name: string;
    version: string;
    source: SourceWithMirrors.t;
    files : Package.File.t list;
    opam : Opam.t option;
  } [@@deriving yojson]

  let compare a b =
    let c = String.compare a.name b.name in
    if c = 0
    then
      let asource, _ = a.source in
      let bsource, _ = b.source in
      Source.compare asource bsource
    else c

  let equal a b =
    String.equal a.name b.name
    && (
      let asource, _ = a.source in
      let bsource, _ = b.source in
      Source.equal asource bsource
    )

  let pp fmt record =
    Fmt.pf fmt "%s@%s" record.name record.version

  module Map = Map.Make(struct type nonrec t = t let compare = compare end)
  module Set = Set.Make(struct type nonrec t = t let compare = compare end)
end

module Id : sig
  type t

  include S.COMPARABLE with type t := t
  include S.JSONABLE with type t := t
  include S.PRINTABLE with type t := t

  val make : name:string -> source:Source.t -> unit -> t
  val ofRecord : Record.t -> t

  module Set : Set.S with type elt = t
  module Map : sig
    include Map.S with type key = t
    val to_yojson : ('a Json.encoder) -> 'a t Json.encoder
    val of_yojson : ('a Json.decoder) -> 'a t Json.decoder
  end
end = struct
  type t = string

  let compare = String.compare
  let equal = String.equal

  let to_yojson = Json.Encode.string
  let of_yojson = Json.Decode.string

  let pp = Fmt.string
  let show v = v

  let make ~name ~(source : Source.t) () =
    let source =
      match source with
      | Source.Orig _ -> Source.show source
      | Source.Override {source = orig; _} ->
        let override =
          source
          |> Source.to_yojson
          |> Yojson.Safe.to_string
          |> Digest.string
          |> Digest.to_hex
        in
        Source.show (Source.Orig orig) ^ "@override:" ^ override
    in
    name ^ "@" ^ source

  let ofRecord record =
    let source, _ = record.Record.source in
    make ~name:record.Record.name ~source ()

  module Set = Set.Make(struct
    type nonrec t = t
    let compare = compare
  end)

  module Map = struct
    include Map.Make(struct
      type nonrec t = t
      let compare = compare
    end)

    let to_yojson v_to_yojson map =
      let items =
        let f k v items = (k, v_to_yojson v)::items in
        fold f map []
      in
      `Assoc items

    let of_yojson v_of_yojson =
      let open Result.Syntax in
      function
      | `Assoc items ->
        let f map (k, v) =
          let%bind v = v_of_yojson v in
          return (add k v map)
        in
        Result.List.foldLeft ~f ~init:empty items
      | _ -> error "expected an object"
  end
end

[@@@ocaml.warning "-32"]
type solution = t

and t = {
  root : Id.t option;
  records : Record.t Id.Map.t;
  dependencies : Id.Set.t Id.Map.t;
}

let root sol =
  match sol.root with
  | Some id -> Id.Map.find_opt id sol.records
  | None -> None

let dependencies (r : Record.t) sol =
  let id = Id.ofRecord r in
  match Id.Map.find_opt id sol.dependencies with
  | None -> Record.Set.empty
  | Some ids ->
    let f id set =
      let record =
        try Id.Map.find id sol.records
        with Not_found ->
          let msg =
            Format.asprintf
              "inconsistent solution, missing record for %a, has:  %a"
              Id.pp id
              Fmt.(list ~sep:(unit "   ") Id.pp) (List.map ~f:fst (Id.Map.bindings sol.records))
          in
          failwith msg
      in
      Record.Set.add record set
    in
    Id.Set.fold f ids Record.Set.empty

let records sol =
  let f _k record records = Record.Set.add record records in
  Id.Map.fold f sol.records Record.Set.empty

let empty = {
  root = None;
  records = Id.Map.empty;
  dependencies = Id.Map.empty;
}

let add ~(record : Record.t) ~dependencies sol =
  let id = Id.ofRecord record in
  let dependencies = Id.Set.of_list dependencies in
  {
    sol with
    records = Id.Map.add id record sol.records;
    dependencies = Id.Map.add id dependencies sol.dependencies;
  }

let addRoot ~(record : Record.t) ~dependencies sol =
  let id = Id.ofRecord record in
  let sol = add ~record ~dependencies sol in
  {sol with root = Some id;}

module LockfileV1 = struct

  type t = {
    (* This is hash of all dependencies/resolutios, used as a checksum. *)
    hash : string;
    (* Id of the root package. *)
    root : Id.t;
    (* Map from ids to nodes. *)
    node : node Id.Map.t
  }

  (* Each package is represented as node. *)
  and node = {
    (* Actual package record. *)
    record : Record.t;
    (* List of dependency ids. *)
    dependencies : Id.t list;
  } [@@deriving yojson]

  let computeSandboxChecksum (sandbox : Sandbox.t) =

    let ppDependencies fmt deps =

      let ppOpamDependencies fmt deps =
        let ppDisj fmt disj =
          match disj with
          | [] -> Fmt.unit "true" fmt ()
          | [dep] -> Package.Dep.pp fmt dep
          | deps -> Fmt.pf fmt "(%a)" Fmt.(list ~sep:(unit " || ") Package.Dep.pp) deps
        in
        Fmt.pf fmt "@[<h>[@;%a@;]@]" Fmt.(list ~sep:(unit " && ") ppDisj) deps
      in

      let ppNpmDependencies fmt deps =
        let ppDnf ppConstr fmt f =
          let ppConj = Fmt.(list ~sep:(unit " && ") ppConstr) in
          Fmt.(list ~sep:(unit " || ") ppConj) fmt f
        in
        let ppVersionSpec fmt spec =
          match spec with
          | VersionSpec.Npm f ->
            ppDnf SemverVersion.Constraint.pp fmt f
          | VersionSpec.NpmDistTag (tag, _version) ->
            Fmt.string fmt tag
          | VersionSpec.Opam f ->
            ppDnf OpamPackageVersion.Constraint.pp fmt f
          | VersionSpec.Source src ->
            Fmt.pf fmt "%a" SourceSpec.pp src
        in
        let ppReq fmt req =
          Fmt.fmt "%s@%a" fmt req.Req.name ppVersionSpec req.spec
        in
        Fmt.pf fmt "@[<hov>[@;%a@;]@]" (Fmt.list ~sep:(Fmt.unit ", ") ppReq) deps
      in

      match deps with
      | Package.Dependencies.OpamFormula deps -> ppOpamDependencies fmt deps
      | Package.Dependencies.NpmFormula deps -> ppNpmDependencies fmt deps
    in

    let showDependencies (deps : Package.Dependencies.t) =
      Format.asprintf "%a" ppDependencies deps
    in

    let hashDependencies ~dependencies digest =
      Digest.string (digest ^ "__" ^ showDependencies dependencies)
    in
    let hashResolutions ~resolutions digest =
      let f digest (key, version) =
      Digest.string (digest ^ "__" ^ key ^ "__" ^ Version.show version)
      in
      List.fold_left
        ~f ~init:digest
        (PackageJson.Resolutions.entries resolutions)
    in
    let digest =
      Digest.string ""
      |> hashResolutions
        ~resolutions:sandbox.resolutions
      |> hashDependencies
        ~dependencies:sandbox.dependencies
    in
    Digest.to_hex digest

  let relativize sandbox path =
    if Path.equal path sandbox.Sandbox.spec.path
    then Path.(v ".")
    else match Path.relativize ~root:sandbox.spec.path path with
    | Some path -> Path.normalizeAndRemoveEmptySeg path
    | None -> Path.normalizeAndRemoveEmptySeg path

  let derelativize sandbox path =
    if Path.isAbs path
    then Path.normalizeAndRemoveEmptySeg path
    else Path.(sandbox.Sandbox.spec.path // path |> normalizeAndRemoveEmptySeg)

  let solutionOfLockfile ~(sandbox : Sandbox.t) root node =
    let _ = sandbox in
    let f id {record; dependencies} sol =
      if Id.equal root id
      then addRoot ~record ~dependencies sol
      else add ~record ~dependencies sol
    in
    Id.Map.fold f node empty

  let lockfileOfSolution ~(sandbox : Sandbox.t) (sol : solution) =
    let _ = sandbox in
    let root, node =
      let f id record (root, nodes) =
        let dependencies = Id.Map.find id sol.dependencies in
        let root =
          if [%derive.eq: Id.t option] (Some id) sol.root
          then Some record
          else root
        in
        let nodes =
          let id = Id.ofRecord record in
          Id.Map.add
            id
            {record; dependencies = Id.Set.elements dependencies}
            nodes
        in
        root, nodes
      in
      Id.Map.fold f sol.records (None, Id.Map.empty)
    in
    let root =
      match root with
      | Some root -> Id.ofRecord root
      | None -> failwith "empty solution"
    in
    root, node

  let ofFile ~(sandbox : Sandbox.t) (path : Path.t) =
    let open RunAsync.Syntax in
    if%bind Fs.exists path
    then
      let%lwt lockfile =
        let%bind json = Fs.readJsonFile path in
        RunAsync.ofRun (Json.parseJsonWith of_yojson json)
      in
      match lockfile with
      | Ok lockfile ->
        if lockfile.hash = computeSandboxChecksum sandbox
        then
          let solution = solutionOfLockfile ~sandbox lockfile.root lockfile.node in
          return (Some solution)
        else return None
      | Error err ->
        let path =
          Option.orDefault
            ~default:path
            (Path.relativize ~root:sandbox.spec.path path)
        in
        errorf
          "corrupted %a lockfile@\nyou might want to remove it and install from scratch@\nerror: %a"
          Path.pp path Run.ppError err
    else
      return None

  let toFile ~sandbox ~(solution : solution) (path : Path.t) =
    let root, node = lockfileOfSolution ~sandbox solution in
    let hash = computeSandboxChecksum sandbox in
    let lockfile = {hash; node; root} in
    let json = to_yojson lockfile in
    Fs.writeJsonFile ~json path
end
