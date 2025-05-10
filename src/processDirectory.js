const path = require('path')
const fs = require('fs').promises
const cliProgress = require('cli-progress');

const processFile = require('./processFile')

const visitedDirectories = new Set();

const processDirectory = async ({ options, inputPath, progressBar, totalFiles }) => {
  try {
    if (visitedDirectories.has(inputPath)) {
      console.log(`Skipping already visited directory: ${inputPath}`);
      return;
    }

    visitedDirectories.add(inputPath);
    console.log(`Processing directory: ${inputPath}`);

    const files = await fs.readdir(inputPath);

    for (const file of files) {
      const filePath = path.join(inputPath, file);
      const fileStats = await fs.stat(filePath);
      if (fileStats.isFile()) {
        totalFiles.count++;
        progressBar.setTotal(totalFiles.count);
        await processFile({ ...options, filePath });
      } else if (fileStats.isDirectory() && options.includeSubdirectories) {
        totalFiles.count++;
        progressBar.setTotal(totalFiles.count);
        await processDirectory({ options, inputPath: filePath, progressBar, totalFiles });
      }
      progressBar.increment();
    }
  } catch (err) {
    console.error(err.message);
  }
};

module.exports = async ({ options, inputPath }) => {
  const totalFiles = { count: 0 };
  const progressBar = new cliProgress.SingleBar({
    format: 'Processing |{bar}| {percentage}% || {value}/{total} Files || ETA: {eta}s',
    hideCursor: true
  });

  progressBar.start(0, 0);

  await processDirectory({ options, inputPath, progressBar, totalFiles });

  progressBar.stop();
};
