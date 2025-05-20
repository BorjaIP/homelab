#!/bin/bash

set -e

# Disable permission check for data directory
php occ config:system:set check_data_directory_permissions --value=false --type=boolean
