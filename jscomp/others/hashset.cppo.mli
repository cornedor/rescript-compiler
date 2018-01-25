#ifdef TYPE_STRING
type key = string
#elif defined TYPE_INT
type key = int
#else
[%error "unknown type"]
#endif  


type t
val create: int -> t 
val clear: t -> unit

val addDone:  t -> key -> unit
val add: t -> key -> t
val copy: t -> t
  
val has: t -> key -> bool
  
val removeDone: t -> key -> unit
  
val remove: t -> key -> t
  
val forEach: t -> (key  -> unit [@bs]) ->  unit
  
val reduce: t -> 'c -> ( 'c -> key -> 'c [@bs]) ->   'c

val size: t -> int  

val logStats: t -> unit

val toArray: t -> key array 

val ofArray: key array -> t 

val mergeArrayDone: t -> key array -> unit

val mergeArray: t -> key array -> t

val getBucketHistogram: t -> int array
