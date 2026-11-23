///|
/// Cross-compiled Windows demo: recursion, loops, strings, UTF-8 output.
fn fib(n : Int) -> Int {
  if n <= 1 {
    n
  } else {
    fib(n - 1) + fib(n - 2)
  }
}

///|
fn main {
  println("Hello from MoonBit — 这份 exe 是在 Linux 上交叉编译的！")
  let mut sum = 0
  for i = 0; i < 10; i = i + 1 {
    sum = sum + fib(i + 20)
  }
  println("fib(20..29) 之和 = " + sum.to_string())
  println("fib(35) = " + fib(35).to_string())
  let arr = [1, 2, 3, 4, 5]
  let doubled = arr.map(fn(x) { x * 2 })
  let mut s = ""
  for x in doubled {
    s = s + x.to_string() + " "
  }
  println("doubled = " + s)
}
