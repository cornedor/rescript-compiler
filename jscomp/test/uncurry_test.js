'use strict';


function f0(param) {
  return 0;
}

function f1(a0) {
  return a0;
}

function f2(a0, a1) {
  return [
          a0,
          a1
        ];
}

console.log(0);

console.log(0);

console.log([
      0,
      1
    ]);

function xx(_param) {
  while(true) {
    _param = undefined;
    continue ;
  };
}

function log2(logger, message, obj) {
  logger.log2(message, obj);
}

exports.f0 = f0;
exports.f1 = f1;
exports.f2 = f2;
exports.xx = xx;
exports.log2 = log2;
/*  Not a pure module */
