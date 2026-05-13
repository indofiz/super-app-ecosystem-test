import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier';

// AUDIT M-6: tighten linting so Promise-heavy code can't grow unsafe
// patterns silently. `no-floating-promises` + `no-misused-promises` need
// the type-aware parser; we point it at tsconfig.test.json so both src
// and test directories get the same treatment.
export default tseslint.config(
  { ignores: ['dist/**', 'node_modules/**', 'coverage/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  prettier,
  {
    languageOptions: {
      parserOptions: {
        // Type-aware rules need a project with src + test in its include
        // list. tsconfig.eslint.json is that file; it inherits everything
        // from tsconfig.json.
        project: ['./tsconfig.eslint.json'],
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': [
        'error',
        {
          // Allow `async` handlers passed where Express expects a sync
          // RequestHandler — we always wrap them with try/catch + next(err).
          checksVoidReturn: { arguments: false, attributes: false },
        },
      ],
      'no-console': ['warn', { allow: ['warn', 'error'] }],
    },
  },
  {
    // The type-aware rules emit a lot of false-positives against
    // pragmatic `as unknown as X` casts and mock objects in test fixtures.
    // Relax just enough to keep tests practical without weakening src.
    files: ['test/**/*.ts'],
    rules: {
      '@typescript-eslint/no-unsafe-assignment': 'off',
      '@typescript-eslint/no-unsafe-member-access': 'off',
      '@typescript-eslint/no-unsafe-call': 'off',
      '@typescript-eslint/no-unsafe-argument': 'off',
      '@typescript-eslint/no-unsafe-return': 'off',
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/require-await': 'off',
    },
  },
);
