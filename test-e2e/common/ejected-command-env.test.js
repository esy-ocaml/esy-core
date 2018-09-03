// @flow

const path = require('path');
const fs = require('fs-extra');

const {createTestSandbox, promiseExec, skipSuiteOnWindows} = require('../test/helpers');
const fixture = require('./fixture.js');

skipSuiteOnWindows('#301');

describe('ejected command-env', () => {
  it('check that `esy build` ejects a command-env which contains deps and devDeps in $PATH', async () => {
    const p = await createTestSandbox(...fixture.simpleProject);
    await p.esy('build');

    await fs.symlink(
      path.join(p.projectPath, '_esy/default/node_modules'),
      path.join(p.projectPath, 'node_modules'),
    );
    await expect(
      promiseExec('. ./node_modules/.cache/_esy/build/bin/command-env && dep', {
        cwd: p.projectPath,
      }),
    ).resolves.toEqual({stdout: '__dep__\n', stderr: ''});

    await expect(
      promiseExec('. ./node_modules/.cache/_esy/build/bin/command-env && devDep', {
        cwd: p.projectPath,
      }),
    ).resolves.toEqual({stdout: '__devDep__\n', stderr: ''});
  });
});
