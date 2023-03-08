#!/bin/bash
echo "[INFO] Cleanup..."
rm -rf node_modules dist
echo "[INFO] Compiling..."
npm ci
echo "[INFO] Installing ncc..."
npm i -g @vercel/ncc
echo "[INFO] Construct singke distributed js with ncc..."
ncc build index.js --license licenses.txt
echo "[INFO] Cleanup node_modules..."
rm -rf node_modules
echo "[INFO] Done!"