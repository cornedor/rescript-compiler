'use strict';


var a = {
  x: 3,
  y: [1]
};

var b = {
  x: 3,
  y: [1],
  z: 3,
  u: (function (x, y) {
      return x + y | 0;
    })
};

function f(obj) {
  return obj.x + obj.y.length | 0;
}

var u = f(a);

var v = f(b);

exports.a = a;
exports.b = b;
exports.f = f;
exports.u = u;
exports.v = v;
/* u Not a pure module */
