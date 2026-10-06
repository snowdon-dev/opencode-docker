#!/bin/bash

# Start the opencode backend. No api key is exported here on purpose: the key
# travels as a compose file secret (/run/secrets/api_key) that opencode reads
# through the `{file:/run/secrets/api_key}` reference in its config, so the
# value never reaches the container's environment (README, "API key secret").
exec opencode serve \
    --hostname 0.0.0.0 --port 4096
