(*
########
Copyright (c) 2017, Nicolas ASSOUAD <nicolas.assouad@ens.fr>
########
*)

open Printf;;

module type HashDesc = sig
  val load : int;;
  val nb_bucket : int;;
  val hash_function : int -> int;;
end;;

module type S = sig
  type 'a t;;

  val to_string : 'a t -> ('a -> string) -> string;;

  val create : unit -> 'a t;;

  val find : 'a t -> int -> 'a option;;

  val mem : 'a t -> int -> bool;;

  val add : 'a t -> int -> 'a -> unit;;

  val remove : 'a t -> int -> bool;;

  val elem_of : 'a t -> 'a list;;
end;;

module Make(Desc : HashDesc) : S = struct
  module STD_List = List;;
  module List = Lf_list.M;;

  type 'a elem = int * 'a option;;

  type 'a table = 'a bucket Atomic.t array
  and 'a bucket =
    |Initialized of 'a elem List.t
    |Allocated of 'a table
    |Uninitialized
  ;;

  type 'a t = {
    access      : 'a table Atomic.t;
    store       : 'a elem List.t;
    size        : int Atomic.t;
    content     : int Atomic.t;
    access_size : int Atomic.t;
    resize      : int option Atomic.t;
  };;

  let load = Desc.load;;
  let nb_bucket = Desc.nb_bucket;;

  let string_of_elem f e =
    let (k, v) = e in
    match v with
    |Some(x) -> sprintf "(%d, %s)" k (f x)
    |None -> (*sprintf "{%d}" k*) ""
  ;;

  let to_string t f =
    let buf = Buffer.create 17 in
    let rec loop acc r =
      match Atomic.get r with
      |Uninitialized -> Buffer.add_string buf "x, "; acc := !acc + 1
      |Allocated(a') ->
        Buffer.add_string buf "{"; Array.iter (loop acc) a'; Buffer.add_string buf "}"
      |Initialized(_) ->
        Buffer.add_string buf (sprintf "(%d), " !acc); acc := !acc + 1
    in
    Buffer.add_string buf "[";
    Array.iter (loop (ref 0)) (Atomic.get t.access);
    Buffer.add_string buf "]\n";
    Buffer.add_string buf (List.to_string t.store (string_of_elem f));
    Buffer.add_string buf (sprintf "Size %d\n" (Atomic.get t.size));
    Buffer.add_string buf (sprintf "Content %d\n" (Atomic.get t.content));
    Buffer.add_string buf (sprintf "Access_size %d\n" (Atomic.get t.access_size));
    (match Atomic.get t.resize with
    |None -> Buffer.add_string buf (sprintf "Resize None")
    |Some(resize) -> Buffer.add_string buf (sprintf "Resize %d" resize));
    Buffer.contents buf
  ;;

  let split_compare x y =
    let rec loop a b =
      if a = 0 && b = 0 then
        0
      else
        let bit_a = a land 1 in
        let bit_b = b land 1 in
        if bit_a = bit_b then
          loop (a lsr 1) (b lsr 1)
        else if bit_a < bit_b then
          -1
        else
           1
    in
    match x, y with
    |(k1, None), (k2, None) -> loop k1 k2
    |(k1, None), (k2, Some(_)) ->
      let out = loop k1 k2 in if out = 0 then -1 else out
    |(k1, Some(_)), (k2, None) ->
      let out = loop k1 k2 in if out = 0 then 1 else out
    |(k1, Some(_)), (k2, Some(_)) -> loop k1 k2
  ;;

  let get_size_of_access a =
    let rec loop a out =
      match Atomic.get a.(0) with
      |Allocated(a') -> loop a' (nb_bucket * out)
      |_ -> out
    in loop a nb_bucket
  ;;

  let rec help_resize t old_access old_access_size =
    let b = Backoff.create () in
    let new_a = Array.init nb_bucket (fun _ -> Atomic.make Uninitialized) in
    Atomic.set new_a.(0) (Allocated(old_access));
    let rec loop () =
      match Atomic.get t.resize with
      |Some(new_access_size) as old_resize -> begin
        if (get_size_of_access (Atomic.get t.access) >= new_access_size ||
            Atomic.compare_and_set t.access old_access new_a) &&
           ((Atomic.get t.access_size) >= new_access_size ||
           Atomic.compare_and_set t.access_size old_access_size new_access_size)
           && ((Atomic.get t.resize) <> old_resize ||
           Atomic.compare_and_set t.resize old_resize None) then
          check_size t
        else
          (Backoff.once b; loop ())
      end
      |None -> check_size t
    in loop ()
  and check_size t =
    let old_access = Atomic.get t.access in
    let old_access_size = Atomic.get t.access_size in
    let s = Atomic.get t.size in
    let c = Atomic.get t.content in
    match Atomic.get t.resize with
    |Some(_) -> help_resize t old_access old_access_size
    |None when c / s > load ->
      if 2*s <= old_access_size then begin
        ignore(Atomic.compare_and_set t.size s (2*s)); check_size t
      end else if
        Atomic.compare_and_set t.resize None (Some(nb_bucket * old_access_size))
        then begin
        help_resize t old_access old_access_size
        end  else
        check_size t
    |_ -> ()
  ;;

  let create () =
    let l = List.create () in
    let (_, n0) = List.sinsert l (0, None) split_compare in
    let (_, n1) = List.sinsert l (1, None) split_compare in
    let tab = Array.init nb_bucket (fun _ -> Atomic.make Uninitialized) in
    Atomic.set tab.(0) (Initialized(n0));
    Atomic.set tab.(1) (Initialized(n1));
    {
      access      = Atomic.make tab;
      store       = l;
      size        = Atomic.make 2;
      content     = Atomic.make 0;
      access_size = Atomic.make nb_bucket;
      resize      = Atomic.make None;
    }
  ;;

  let hash t k =
    (Desc.hash_function k) mod (Atomic.get t.size)
  ;;

  let get_closest_power n =
    let rec loop out =
      let new_out = out lsl 1 in
      if new_out  > n then
        out
      else
        loop new_out
    in loop 1
  ;;

  let rec get_bucket t hk =
    let rec access_bucket a ind size =
      let tmp_ind = ind / size in
      let new_ind = ind mod size in
      let new_size = size / nb_bucket in
      match Atomic.get a.(tmp_ind) with
      |Uninitialized ->
        initialise_bucket a tmp_ind size; access_bucket a ind size
      |Allocated(a') -> access_bucket a' new_ind new_size
      |Initialized(s) -> s
    and initialise_bucket a ind size =
      let new_elem =
        if size = 1 then begin
          let prev_hk = hk mod (get_closest_power hk) in
          let prev_s = get_bucket t prev_hk in
          match Atomic.get a.(ind) with
          | Initialized(_) as out -> out
          |_ ->
            let (_, s) = List.sinsert prev_s (hk, None) split_compare in
            Initialized(s)
        end else
          Allocated(Array.init nb_bucket (fun _ -> Atomic.make Uninitialized))
      in
      ignore(Atomic.compare_and_set a.(ind) Uninitialized new_elem);
      ()
    in
    let size = (Atomic.get t.access_size) / nb_bucket in
    access_bucket (Atomic.get t.access) hk size
  ;;

  let find t k =
    check_size t;
    let hk = hash t k in
    let s = get_bucket t hk in
    let v = List.find s (k, Some(Obj.magic ())) split_compare in
    match v with
    |Some(_, out) -> out
    |None -> None
  ;;

  let mem t k =
    check_size t;
    let hk = hash t k in
    let s = get_bucket t hk in
    List.mem s (k, Some(Obj.magic ())) split_compare
  ;;


  let add t k v =
    check_size t;
    let hk = hash t k in
    let s = get_bucket t hk in
    let (is_new, _) = List.sinsert s (k, (Some(v))) split_compare in
    if is_new then
      Atomic.incr t.content
  ;;

  let remove t k =
    check_size t;
    let hk = hash t k in
    let s = get_bucket t hk in
    if List.sdelete s (k, Some(Obj.magic ())) split_compare then
      (Atomic.decr t.content; true)
    else false
  ;;

  let elem_of t =
    let rec loop l out =
      match l with
      |(_, Some(x))::t -> loop t (x::out)
      |(_, None)::t -> loop t out
      |[] -> out
    in loop (List.elem_of t.store) []
  ;;
end;;
