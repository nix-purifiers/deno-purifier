import { assertEquals } from "@std/assert";
import { greet } from "./mod.ts";

Deno.test("greet says whether a number is odd", () => {
  assertEquals(greet(3), "hello, odd 3");
  assertEquals(greet(4), "hello, even 4");
});
