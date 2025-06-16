# Claude Development Notes

## Build Process
- **Never run build commands** - the user has `npm run dev` running which handles automatic rebuilds
- Changes to TypeScript files are automatically compiled and watched
- Do not run `npm run build:client` or similar build commands

## Development Workflow
- Make changes to source files in `src/`
- The dev server automatically rebuilds and reloads
- Focus on editing source files, not built artifacts