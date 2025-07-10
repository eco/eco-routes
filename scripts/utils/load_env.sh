#!/usr/bin/env bash
#
# load_env.sh
#
# Utility for loading environment variables while preserving existing values.
# Unlike direct loading of .env which overwrites existing variables, this script
# only sets variables that aren't already defined in the environment.
#
# This allows for environment variables to be passed from parent processes
# (like TypeScript scripts) that won't be overridden by values in .env files.
#
# Usage:
#   source /path/to/load_env.sh
#   load_env [optional_env_file_path]
#
# If no env file path is provided, it defaults to ".env" in the current directory.
load_env() {
  local env_file="$1"
  
  # Default to .env if no file is specified
  if [ -z "$env_file" ]; then
    env_file=".env"
  fi
  
  # Check if the file exists
  if [ -f "$env_file" ]; then
    # Read the file line by line
    while IFS= read -r line || [ -n "$line" ]; do
      # Skip empty lines and comments
      [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
      
      # Extract variable name and value
      var_name=$(echo "$line" | cut -d= -f1)
      
      # Only set if not already in environment
      if [ -z "${!var_name}" ]; then
        # Use eval to handle complex variable values properly
        eval "export $line"
      fi
    done < "$env_file"
  fi
}

# Export the function so it can be called from other scripts
export -f load_env