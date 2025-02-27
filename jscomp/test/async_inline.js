'use strict';

var Curry = require("../../lib/js/curry.js");

async function willBeInlined(param) {
  return 3;
}

var inlined = willBeInlined(undefined);

function wrapSomethingAsync(param) {
  ((async function (param) {
          var test = await Promise.resolve("Test");
          console.log(test);
        })(777));
}

function wrapSomethingAsync2(param) {
  ((async function (param) {
          var test = await Promise.resolve("Test");
          console.log(test);
        })(undefined));
}

async function doSomethingAsync(someAsyncFunction) {
  return await Curry._1(someAsyncFunction, undefined);
}

var broken = doSomethingAsync;

var M = {
  broken: broken
};

async function broken$1(someAsyncFunction) {
  return await Curry._1(someAsyncFunction, undefined);
}

var broken$2 = broken$1;

function curriedId(x) {
  return x;
}

async function curriedIdAsync(x) {
  return x;
}

function uncurriedId(x) {
  return x;
}

async function uncurriedIdAsync(x) {
  return x;
}

var tcia = curriedIdAsync(3);

var tui = 3;

var tuia = uncurriedIdAsync(3);

var tci = 3;

exports.willBeInlined = willBeInlined;
exports.inlined = inlined;
exports.wrapSomethingAsync = wrapSomethingAsync;
exports.wrapSomethingAsync2 = wrapSomethingAsync2;
exports.M = M;
exports.broken = broken$2;
exports.curriedId = curriedId;
exports.curriedIdAsync = curriedIdAsync;
exports.uncurriedId = uncurriedId;
exports.uncurriedIdAsync = uncurriedIdAsync;
exports.tci = tci;
exports.tcia = tcia;
exports.tui = tui;
exports.tuia = tuia;
/* inlined Not a pure module */
