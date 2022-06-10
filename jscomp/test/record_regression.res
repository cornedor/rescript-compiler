// @@config({flags: ["-bs-diagnose"] })

type t0 = {x: int, @optional y: int, @optional yy: option<int>, z: int}

let f1 = {x: 3, z: 2}

let f2 = {x: 3, z: 3, y: 3}

let f3 = {...f1, y: 3}

let f4 = {...f3, yy: None}

let theseTwoShouldBeIdentical = [f4.yy, (Some(None): option<option<int>>)]

type r = {
  x: int,
  y: option<int>,
  z: int,
}

// let v0 = { x :  3 , z : 2 }

// let v2 = { ... v0 , x : 3 }

let v1: t0 = {
  x: 3,
  z: 3,
}

let v2: r = {x: 3, y: None, z: 2}

@obj
type config = {
  x: int,
  y0: option<int>,
  y1: option<int>,
  y2: option<int>,
  y3: option<int>,
  y4: option<int>,
  y5: option<int>,
  y6: option<int>,
  y7: option<int>,
  y8: option<int>,
  y9: option<int>,
  y10: option<int>,
  y11: option<int>,
  y12: option<int>,
  y13: option<int>,
  y14: option<int>,
  y15: option<int>,
  y16: option<int>,
  y17: option<int>,
  y18: option<int>,
  y19: option<int>,
  y20: option<int>,
  y21: option<int>,
  y22: option<int>,
  y23: option<int>,
  z: int,
}

let v: config = {x: 2, z: 3}

let h: config = {...v, y1: 22}

type small_config = {
  x: int,
  @optional y0: int,
  @optional y1: int,
  z: int,
}

let v1: small_config = {x: 2, z: 3}

let h10: small_config = {...v1, y1: 22}

let h11 = (v1): small_config => {
  {...v1, y1: 22}
}

type partiallyOptional = {
  @optional aa: int,
  bb: option<int>,
}

let po = {aa: 3, bb: Some(4)}

// module M: {
//   type partiallyOptional = {
//     @optional aa: int,
//     bb: option<int>,
//   }
// } = {
//   type partiallyOptional = {
//     @optional aa: int,
//     @optional bb: int,
//   }
// }
