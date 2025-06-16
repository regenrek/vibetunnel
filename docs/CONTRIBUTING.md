# Contributing to VibeTunnel

We love your input! We want to make contributing to VibeTunnel as easy and transparent as possible, whether it's:

- Reporting a bug
- Discussing the current state of the code
- Submitting a fix
- Proposing new features
- Becoming a maintainer

## We Develop with Github

We use GitHub to host code, to track issues and feature requests, as well as accept pull requests.

## We Use [Github Flow](https://guides.github.com/introduction/flow/index.html)

Pull requests are the best way to propose changes to the codebase:

1. Fork the repo and create your branch from `main`.
2. If you've added code that should be tested, add tests.
3. If you've changed APIs, update the documentation.
4. Ensure the test suite passes.
5. Make sure your code lints.
6. Issue that pull request!

## Any contributions you make will be under the MIT Software License

In short, when you submit code changes, your submissions are understood to be under the same [MIT License](LICENSE) that covers the project. Feel free to contact the maintainers if that's a concern.

## Report bugs using Github's [issues](https://github.com/amantus-ai/vibetunnel/issues)

We use GitHub issues to track public bugs. Report a bug by [opening a new issue](https://github.com/amantus-ai/vibetunnel/issues/new).

**Great Bug Reports** tend to have:

- A quick summary and/or background
- Steps to reproduce
  - Be specific!
  - Give sample code if you can
- What you expected would happen
- What actually happens
- Notes (possibly including why you think this might be happening, or stuff you tried that didn't work)

## Development Setup

1. **Fork and clone the repository**
   ```bash
   git clone https://github.com/[your-username]/vibetunnel.git
   cd vibetunnel
   ```

2. **Install dependencies**
   - Xcode 15.0+ for Swift development
   - Rust toolchain: `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
   - Node.js 18+: `brew install node`

3. **Build the project**
   ```bash
   # Build Rust server
   cd tty-fwd && cargo build && cd ..
   
   # Build web frontend
   cd web && npm install && npm run build && cd ..
   
   # Open in Xcode
   open VibeTunnel.xcodeproj
   ```

## Code Style

### Swift
- We use SwiftFormat and SwiftLint with configurations optimized for Swift 6
- Run `swiftformat .` and `swiftlint` before committing
- Follow Swift API Design Guidelines

### Rust
- Use `cargo fmt` before committing
- Run `cargo clippy` and fix any warnings

### TypeScript/JavaScript
- We use Prettier for formatting
- Run `npm run format` in the web directory

## Testing

- Write tests for new functionality
- Ensure all tests pass before submitting PR
- Include both positive and negative test cases

## License

By contributing, you agree that your contributions will be licensed under its MIT License.

## References

This document was adapted from the open-source contribution guidelines for [Facebook's Draft](https://github.com/facebook/draft-js/blob/master/CONTRIBUTING.md).