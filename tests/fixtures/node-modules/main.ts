// Imports a dependency of package.json, which Deno installs into
// node_modules.
import isOdd from "is-odd";

const n = Number(Deno.args[0] ?? "3");
console.log(`${n} is ${isOdd(n) ? "odd" : "even"}`);
