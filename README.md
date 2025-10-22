# Dockerized App Deployment Script
This script automates the setup, deployment, and configuration of a Dockerized application on a remote Linux server. It collects user inputs, clones or pulls the Git repository, establishes SSH connection, prepares the remote environment (installing Docker, Docker Compose, and Nginx if needed), transfers files, deploys the application (using Dockerfile or docker-compose.yml), configures Nginx as a reverse proxy, and provides an optional cleanup mode.

# Requirements
* Git for cloning/pulling the repository.
* SSH key for remote access (no password auth).
* Sudo access for the SSH user.
* Internet access for package installations.
* Git Repository must contain either a Dockerfile (for single-container) or docker-compose.yml.

# Installation
1. Make the script executable by running : `chmod +x deploy.sh`.
2. Run the script with `bash deploy.sh`  or `./deploy.sh`
