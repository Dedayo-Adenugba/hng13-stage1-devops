# hng13-stage1-devops
Repository for HNG13 stage1devops task# Automated Nginx Deployment Script

This Bash script automates the deployment of a web application using **Nginx** as the web server.  
It performs the following operations:
- Clones or updates your GitHub repository  
- Synchronizes project files to a remote server via SSH  
- Installs and configures Nginx  
- Deploys a web application and sets up a reverse proxy  
- Logs all operations for auditing and debugging  

---

## 🧩 Features

- Automated Git clone and update
- Remote synchronization using `rsync`
- Nginx setup and configuration
- Dynamic port handling and process checks
- Logging for every deployment action
- Clean and modular design for easy reuse

---

## ⚙️ Prerequisites

Before running this script, ensure:

1. You have **Bash**, **Git**, **rsync**, and **SSH** installed on your local machine.
2. You have access to a **remote Linux server** (Ubuntu recommended).
3. Nginx is **not already running** or you’re ready to overwrite its default configuration.
4. Your SSH key has access to the remote server.

---

## 🗝️ Required Inputs

When you run the script, it will prompt for the following:

| Input | Description |
|-------|--------------|
| GitHub Repository URL | URL of your project repo |
| GitHub PAT | Your GitHub Personal Access Token |
| Branch Name | The branch to deploy (e.g. `main`) |
| Remote Username | SSH username of your remote server |
| Server IP | IP address of the remote server |
| SSH Key Path | Path to your private SSH key |
| App Port | Internal port your app runs on (e.g. 3000) |

---

## 🚀 How to Run

### Step 1 — Make the script executable
```bash
chmod +x deploy.sh

