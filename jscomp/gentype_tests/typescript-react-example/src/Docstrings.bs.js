// Generated by ReScript, PLEASE EDIT WITH CARE


function signMessage(message, key) {
  return message + String(key);
}

function one(a) {
  return a + 0 | 0;
}

function two(a, b) {
  return (a + b | 0) + 0 | 0;
}

function tree(a, b, c) {
  return ((a + b | 0) + c | 0) + 0 | 0;
}

function oneU(a) {
  return a + 0 | 0;
}

function twoU(a, b) {
  return (a + b | 0) + 0 | 0;
}

function treeU(a, b, c) {
  return ((a + b | 0) + c | 0) + 0 | 0;
}

function useParam(param) {
  return param + 34 | 0;
}

function useParamU(param) {
  return param + 34 | 0;
}

function unnamed1(param) {
  return 34;
}

function unnamed1U(param) {
  return 34;
}

function unnamed2(param, param$1) {
  return 34;
}

function unnamed2U(param, param$1) {
  return 34;
}

function grouped(x, y, a, b, c, z) {
  return ((((x + y | 0) + a | 0) + b | 0) + c | 0) + z | 0;
}

function unitArgWithoutConversion(param) {
  return "abc";
}

function unitArgWithoutConversionU(param) {
  return "abc";
}

function unitArgWithConversion(param) {
  return /* A */0;
}

function unitArgWithConversionU(param) {
  return /* A */0;
}

var flat = 34;

export {
  flat ,
  signMessage ,
  one ,
  two ,
  tree ,
  oneU ,
  twoU ,
  treeU ,
  useParam ,
  useParamU ,
  unnamed1 ,
  unnamed1U ,
  unnamed2 ,
  unnamed2U ,
  grouped ,
  unitArgWithoutConversion ,
  unitArgWithoutConversionU ,
  unitArgWithConversion ,
  unitArgWithConversionU ,
}
/* No side effect */
