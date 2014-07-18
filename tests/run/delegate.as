extern def puts(str);
extern def printf(str, int);

# Declare a function that prints something.
def printer() { puts("Hello"); }

# Declare a named function that takes a function.
def call_twice(fn: delegate()) { fn(); fn(); }

# Declare a function that takes and returns an int.
def some(x: int): int { x; }

# Declare a named function that returns a function.
def that(): delegate(int) -> int { some; }

def main() {
    # Declare a slot for a function type that takes and returns an int.
    let action = that();

    # Declare a slot for a function that takes and returns nothing.
    let pure = printer;

    # Invoke the higher-order function to call us twice.
    call_twice(printer);
    call_twice(pure);

    # Print the result of returning.
    printf("%d", action(3210));
    printf("%c", 0x0A);

    # FIXME: issue #11
    # printf("%d", that()(3210));
    # printf("%c", 0x0A);
}
