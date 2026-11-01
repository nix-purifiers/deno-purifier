import isOdd from "is-odd";

/** Greets a number, saying whether it is odd. */
export function greet(n: number): string {
  return `hello, ${isOdd(n) ? "odd" : "even"} ${n}`;
}
