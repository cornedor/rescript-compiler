external bswap16: int -> int = "%bswap16"
external bswap32: int32 -> int32 = "%bswap_int32"
external bswap64: int64 -> int64 = "%bswap_int64"


let tests_16 =
[|(1, 256); (2, 512); (4, 1024); (8, 2048); (16, 4096); (32, 8192);
  (64, 16384); (128, 32768); (256, 1); (512, 2); (1024, 4); (2048, 8);
  (4096, 16); (8192, 32); (16384, 64); (32768, 128)|]


let tests_32 = 
  [|(1l, 16777216l); (2l, 33554432l); (4l, 67108864l); (8l, 134217728l);
  (16l, 268435456l); (32l, 536870912l); (64l, 1073741824l);
  (128l, -2147483648l); (256l, 65536l); (512l, 131072l); (1024l, 262144l);
  (2048l, 524288l); (4096l, 1048576l); (8192l, 2097152l); (16384l, 4194304l);
  (32768l, 8388608l); (65536l, 256l); (131072l, 512l); (262144l, 1024l);
  (524288l, 2048l); (1048576l, 4096l); (2097152l, 8192l); (4194304l, 16384l);
  (8388608l, 32768l); (16777216l, 1l); (33554432l, 2l); (67108864l, 4l);
  (134217728l, 8l); (268435456l, 16l); (536870912l, 32l); (1073741824l, 64l);
  (-2147483648l, 128l)|]

let tests_64 = 
[|(1L, 72057594037927936L); (2L, 144115188075855872L);
  (4L, 288230376151711744L); (8L, 576460752303423488L);
  (16L, 1152921504606846976L); (32L, 2305843009213693952L);
  (64L, 4611686018427387904L); (128L, -9223372036854775808L);
  (256L, 281474976710656L); (512L, 562949953421312L);
  (1024L, 1125899906842624L); (2048L, 2251799813685248L);
  (4096L, 4503599627370496L); (8192L, 9007199254740992L);
  (16384L, 18014398509481984L); (32768L, 36028797018963968L);
  (65536L, 1099511627776L); (131072L, 2199023255552L);
  (262144L, 4398046511104L); (524288L, 8796093022208L);
  (1048576L, 17592186044416L); (2097152L, 35184372088832L);
  (4194304L, 70368744177664L); (8388608L, 140737488355328L);
  (16777216L, 4294967296L); (33554432L, 8589934592L);
  (67108864L, 17179869184L); (134217728L, 34359738368L);
  (268435456L, 68719476736L); (536870912L, 137438953472L);
  (1073741824L, 274877906944L); (2147483648L, 549755813888L);
  (4294967296L, 16777216L); (8589934592L, 33554432L);
  (17179869184L, 67108864L); (34359738368L, 134217728L);
  (68719476736L, 268435456L); (137438953472L, 536870912L);
  (274877906944L, 1073741824L); (549755813888L, 2147483648L);
  (1099511627776L, 65536L); (2199023255552L, 131072L);
  (4398046511104L, 262144L); (8796093022208L, 524288L);
  (17592186044416L, 1048576L); (35184372088832L, 2097152L);
  (70368744177664L, 4194304L); (140737488355328L, 8388608L);
  (281474976710656L, 256L); (562949953421312L, 512L);
  (1125899906842624L, 1024L); (2251799813685248L, 2048L);
  (4503599627370496L, 4096L); (9007199254740992L, 8192L);
  (18014398509481984L, 16384L); (36028797018963968L, 32768L);
  (72057594037927936L, 1L); (144115188075855872L, 2L);
  (288230376151711744L, 4L); (576460752303423488L, 8L);
  (1152921504606846976L, 16L); (2305843009213693952L, 32L);
  (4611686018427387904L, 64L); (-9223372036854775808L, 128L)|]

let suites_16 = 
  tests_16 
  |> Array.to_list  
  |> List.map 
    (fun (a,b) -> (Printf.sprintf "swap16 %d" a,
                   fun _ -> Mt.Eq(bswap16 a , b)))
let suites_32 = 
  tests_32 
  |> Array.to_list
  |> List.map 
    (fun (a,b) -> (Printf.sprintf "swap32 %d" (Int32.to_int a),
                   fun _ -> Mt.Eq(bswap32 a , b)))

let suites_64 = 
  tests_64 
  |> Array.to_list
  |> List.map 
    (fun (a,b) -> (Printf.sprintf "swap64 %d" (Int64.to_int a),
                   fun _ -> Mt.Eq(bswap64 a , b)))







let d16 = 
  format_of_string "%x",
  bswap16,
  [|
    0x11223344, "4433";
    0x0000f0f0, "f0f0"
  |]

let d32 = 
  format_of_string "%lx",
  bswap32,
  [|
    0x11223344l, "44332211";
    0xf0f0_f0f0l,"f0f0f0f0"
  |]

(* let d64 () = *)
(*   format_of_string "%Lx", *)

(*   [| *)
(*     0x1122334455667788L, "8877665544332211"; *)
(*     0xf0f0f0f0f0f0f0f0L,"f0f0f0f0f0f0f0f0" *)
(*   |] *)

let f = Format.asprintf 

let f  s (* : 'a . ('a -> 'b, Format.formatter, unit, string) format4 * ('a * 'b) array -> *)
  (* (string * ('c -> 'd Mt.eq)) list *)  = fun (x, swap, ls) -> 
  Array.mapi (fun i (a,  b) -> f "%s %i" s i, fun _ -> Mt.Eq (f x (swap a), b) ) ls
  |> Array.to_list

;; Mt.from_pair_suites __MODULE__ 
  (suites_16 @ suites_32  @ suites_64 
   @ f "d16" d16 
   @ f "d32" d32 
   (* @ f (d64 ()) *)
  )
