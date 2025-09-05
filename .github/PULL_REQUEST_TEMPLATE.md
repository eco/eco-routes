## Pull Request Title Format

Please ensure your PR title follows the [Conventional Commit](https://www.conventionalcommits.org/) format:

```
<type>[optional scope]: <description>
```

### Allowed Types:

- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation only changes
- `style`: Changes that do not affect the meaning of the code
- `refactor`: A code change that neither fixes a bug nor adds a feature
- `test`: Adding missing tests or correcting existing tests
- `chore`: Changes to build process or auxiliary tools
- `perf`: A code change that improves performance
- `ci`: Changes to CI configuration files and scripts
- `build`: Changes that affect the build system or external dependencies
- `revert`: Reverts a previous commit

### Examples:

✅ `feat: add cross-chain intent validation`
✅ `fix: resolve memory leak in prove method`
✅ `docs: update API documentation for routes`
✅ `refactor(inbox): simplify refund logic`
✅ `test: add edge case coverage for token transfers`
✅ `chore: update dependencies to latest versions`

### Important Notes:

- The description should be lowercase and not end with a period
- Use present tense ("add" not "added" or "adds")
- Scopes are optional but helpful for organizing changes
- If you need to bypass this check temporarily, add the label `skip-pr-title-check`

---

## Description

<!-- Provide a brief description of the changes in this PR -->

## Type of Change

<!-- Mark the appropriate option with an "x" -->

- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Test improvements
- [ ] Code refactoring
- [ ] Performance improvement
- [ ] CI/Build changes
