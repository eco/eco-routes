#!/usr/bin/env ts-node

import * as fs from 'fs';
import * as path from 'path';
import { Command } from 'commander';

interface ForgeArtifact {
  abi: any[];
  bytecode: {
    object: string;
    sourceMap: string;
    linkReferences?: Record<string, any>;
  };
  deployedBytecode: {
    object: string;
    sourceMap: string;
    linkReferences?: Record<string, any>;
    immutableReferences?: Record<string, any>;
  };
  id: string;
  metadata: {
    compiler: {
      version: string;
    };
    sources: Record<string, {
      keccak256: string;
      license?: string;
      urls: string[];
    }>;
    settings: {
      compilationTarget: Record<string, string>;
      evmVersion: string;
      libraries: Record<string, any>;
      metadata: {
        bytecodeHash: string;
      };
      optimizer: {
        enabled: boolean;
        runs: number;
      };
      remappings: string[];
    };
    version: number;
  };
  methodIdentifiers: Record<string, string>;
  rawMetadata: string;
}

interface TronboxArtifact {
  contractName: string;
  abi: any[];
  bytecode: string;
  deployedBytecode: string;
  source: string;
  sourcePath: string;
}

function extractContractNameFromPath(forgePath: string): string {
  // Extract from path like "out/Portal.sol/Portal.json"
  const pathParts = forgePath.split('/');
  const jsonFile = pathParts[pathParts.length - 1];
  return path.basename(jsonFile, '.json');
}

function extractSourcePathFromMetadata(metadata: ForgeArtifact['metadata']): string {
  // Get the first source file path from compilation target
  const compilationTarget = metadata.settings.compilationTarget;
  const sourcePath = Object.keys(compilationTarget)[0];
  return sourcePath || '';
}

function extractSourceContent(metadata: ForgeArtifact['metadata'], sourcePath: string): string {
  // In a real implementation, you might want to read the actual source file
  // For now, we'll generate a placeholder based on the compilation target
  const contractName = Object.values(metadata.settings.compilationTarget)[0];
  
  return `// SPDX-License-Identifier: MIT
pragma solidity ^${metadata.compiler.version.split('+')[0]};

/**
 * @title ${contractName}
 * @dev Contract compiled with Forge and converted to Tronbox format
 * @dev Original source: ${sourcePath}
 */
contract ${contractName} {
    // Contract implementation
    // Note: This is a placeholder. Original source should be preserved.
}`;
}

function convertForgeToTronbox(forgeArtifact: ForgeArtifact, contractName: string): TronboxArtifact {
  const sourcePath = extractSourcePathFromMetadata(forgeArtifact.metadata);
  const source = extractSourceContent(forgeArtifact.metadata, sourcePath);

  return {
    contractName,
    abi: forgeArtifact.abi,
    bytecode: forgeArtifact.bytecode.object.startsWith('0x') 
      ? forgeArtifact.bytecode.object 
      : '0x' + forgeArtifact.bytecode.object,
    deployedBytecode: forgeArtifact.deployedBytecode.object.startsWith('0x')
      ? forgeArtifact.deployedBytecode.object
      : '0x' + forgeArtifact.deployedBytecode.object,
    source,
    sourcePath
  };
}

function ensureDirectoryExists(dirPath: string): void {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
    console.log(`✅ Created directory: ${dirPath}`);
  }
}

function convertFile(inputPath: string, outputDir: string): void {
  console.log(`🔄 Converting ${inputPath}...`);
  
  // Validate input file exists
  if (!fs.existsSync(inputPath)) {
    console.error(`❌ Error: Input file does not exist: ${inputPath}`);
    process.exit(1);
  }

  // Read and parse Forge artifact
  let forgeArtifact: ForgeArtifact;
  try {
    const fileContent = fs.readFileSync(inputPath, 'utf8');
    forgeArtifact = JSON.parse(fileContent);
  } catch (error) {
    console.error(`❌ Error reading/parsing input file: ${error}`);
    process.exit(1);
  }

  // Validate it's a proper Forge artifact
  if (!forgeArtifact.abi || !forgeArtifact.bytecode || !forgeArtifact.metadata) {
    console.error('❌ Error: Input file does not appear to be a valid Forge artifact');
    process.exit(1);
  }

  // Extract contract name
  const contractName = extractContractNameFromPath(inputPath);
  console.log(`📋 Contract name: ${contractName}`);

  // Convert to Tronbox format
  const tronboxArtifact = convertForgeToTronbox(forgeArtifact, contractName);

  // Ensure output directory exists
  ensureDirectoryExists(outputDir);

  // Write output file
  const outputPath = path.join(outputDir, `${contractName}.json`);
  try {
    fs.writeFileSync(outputPath, JSON.stringify(tronboxArtifact, null, 2));
    console.log(`✅ Successfully converted to: ${outputPath}`);
  } catch (error) {
    console.error(`❌ Error writing output file: ${error}`);
    process.exit(1);
  }

  // Display summary
  console.log('\n📊 Conversion Summary:');
  console.log(`   Contract: ${contractName}`);
  console.log(`   ABI Functions: ${tronboxArtifact.abi.length}`);
  console.log(`   Bytecode Size: ${Math.floor(tronboxArtifact.bytecode.length / 2)} bytes`);
  console.log(`   Source Path: ${tronboxArtifact.sourcePath}`);
}

// CLI Setup
const program = new Command();

program
  .name('forge-to-tronbox')
  .description('Convert Forge build artifacts to Tronbox format')
  .version('1.0.0')
  .argument('<input>', 'Path to Forge artifact JSON file (e.g., out/Portal.sol/Portal.json)')
  .option(
    '-o, --output <dir>', 
    'Output directory for Tronbox artifacts', 
    'tronbox/build/contracts'
  )
  .option('-v, --verbose', 'Enable verbose output')
  .action((input: string, options: { output: string; verbose?: boolean }) => {
    if (options.verbose) {
      console.log('🔧 Forge to Tronbox Converter');
      console.log('================================');
      console.log(`Input: ${input}`);
      console.log(`Output: ${options.output}`);
      console.log('');
    }

    // Resolve paths
    const inputPath = path.resolve(input);
    const outputDir = path.resolve(options.output);

    convertFile(inputPath, outputDir);
  });

// Add batch conversion command
program
  .command('batch')
  .description('Convert multiple Forge artifacts at once')
  .argument('<pattern>', 'Glob pattern for input files (e.g., "out/**/*.json")')
  .option(
    '-o, --output <dir>',
    'Output directory for Tronbox artifacts',
    'tronbox/build/contracts'
  )
  .option('-v, --verbose', 'Enable verbose output')
  .action((pattern: string, options: { output: string; verbose?: boolean }) => {
    const glob = require('glob');
    
    console.log('🔧 Batch Forge to Tronbox Converter');
    console.log('===================================');
    
    const files = glob.sync(pattern);
    
    if (files.length === 0) {
      console.log(`⚠️  No files found matching pattern: ${pattern}`);
      return;
    }

    console.log(`📁 Found ${files.length} files to convert`);
    
    const outputDir = path.resolve(options.output);
    
    files.forEach((file: string, index: number) => {
      console.log(`\n[${index + 1}/${files.length}] Converting ${file}`);
      try {
        convertFile(path.resolve(file), outputDir);
      } catch (error) {
        console.error(`❌ Failed to convert ${file}: ${error}`);
      }
    });

    console.log('\n🎉 Batch conversion completed!');
  });

// Add info command to analyze file formats
program
  .command('info')
  .description('Analyze and display information about build artifacts')
  .argument('<file>', 'Path to build artifact JSON file')
  .action((file: string) => {
    const filePath = path.resolve(file);
    
    if (!fs.existsSync(filePath)) {
      console.error(`❌ Error: File does not exist: ${filePath}`);
      process.exit(1);
    }

    try {
      const content = JSON.parse(fs.readFileSync(filePath, 'utf8'));
      
      console.log('📋 Build Artifact Information');
      console.log('=============================');
      console.log(`File: ${filePath}`);
      console.log(`Top-level keys: ${Object.keys(content).join(', ')}`);
      
      if (content.contractName) {
        console.log(`Format: Tronbox`);
        console.log(`Contract: ${content.contractName}`);
        console.log(`ABI entries: ${content.abi?.length || 0}`);
        console.log(`Source path: ${content.sourcePath || 'N/A'}`);
      } else if (content.metadata) {
        console.log(`Format: Forge`);
        const compilationTarget = content.metadata?.settings?.compilationTarget || {};
        const contractName = Object.values(compilationTarget)[0] || 'Unknown';
        console.log(`Contract: ${contractName}`);
        console.log(`ABI entries: ${content.abi?.length || 0}`);
        console.log(`Compiler: ${content.metadata?.compiler?.version || 'N/A'}`);
      } else {
        console.log(`Format: Unknown`);
      }
      
    } catch (error) {
      console.error(`❌ Error reading file: ${error}`);
    }
  });

// Parse command line arguments
program.parse();