# `systemd` Service Configurations

## Purpose

These services are alternative configurations and setups that can be selectively enabled when standard configurations don't meet requirements, mainly permission requirements.

## Usage

### Installation

```bash
sudo cp ./services/systemd/example.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable example.service
sudo systemctl start example.service
```
