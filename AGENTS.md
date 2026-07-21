This is a Zig 0.16 project building a Caddy-free PHP application server.

You always need to follow these rules without exceptions:
- Split files into smaller ones if makes sense but don't over do it.
- Use comments and documentation where needed
- Keep your code clean and readable
- Avoid code duplication
- Avoid creating random helpers everywhere in unrelated parts of the projects
- Ignore backwards compatibility of any kind, we aim for the best solution in any case. If some code needs refactoring we will fix alse that.
- To test behavior, create an example PHP file in the tests folder and run it
