'use strict';


function f(x) {
  return x.length + x.width;
}

function chain(x) {
  return x.element.length + x.element.length | 0;
}

exports.f = f;
exports.chain = chain;
/* No side effect */
