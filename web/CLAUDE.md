# Claude Development Notes

## Build Process
- **Never run build commands** - the user has `npm run dev` running which handles automatic rebuilds
- Changes to TypeScript files are automatically compiled and watched
- Do not run `npm run build:client` or similar build commands

## Development Workflow
- Make changes to source files in `src/`
- The dev server automatically rebuilds and reloads
- Focus on editing source files, not built artifacts

## Server Execution
- NEVER RUN THE SERVER YOURSELF, I ALWAYS RUN IT ON THE SIDE VIA NPM RUN DEV!

## Code Quality
- ESLint and Prettier are configured for the project
- Run `npm run lint` to check for linting issues
- Run `npm run lint:fix` to automatically fix most issues
- Run `npm run format` to format all code with Prettier
- Run `npm run format:check` to check formatting without changing files