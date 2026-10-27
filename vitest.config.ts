import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    include: ['tests/project/**/*.test.ts'],
    // every file spawns pwsh: under load a single case can exceed the 5 s default
    testTimeout: 30000,
    hookTimeout: 30000,
  },
});
