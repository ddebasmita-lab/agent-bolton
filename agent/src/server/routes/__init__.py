#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os

from src.server.routes.chat import chat_bp
from src.server.routes.dcproxy import dcproxy_bp
from src.server.routes.health import health_bp
from src.server.routes.system import system_bp
from src.server.routes.tools import tools_bp

# Blueprints declare their routes at the root (/chat/stream, /health) and get
# the prefix applied here. Override it with AGENT_API_PREFIX if it collides
# with a path your own front end already uses; the data-plane routes dcproxy
# owns sit at the root and are unaffected.
_API_PREFIX = os.environ.get("AGENT_API_PREFIX", "/agent")


def register_all(app):
    """Register every route blueprint.

    Registration order is not significant -- Werkzeug matches on rule
    specificity, not registration order -- but the grouping reflects who owns
    which URL space:

      /agent/*                  the agent's own API
      /core, /api, /tools, ...  the data plane, reverse-proxied by dcproxy
      /healthz                  the Cloud Run startup probe
    """
    for bp in (system_bp, tools_bp, chat_bp):
        app.register_blueprint(bp, url_prefix=_API_PREFIX)

    # No prefix: these own the browser-facing root.
    app.register_blueprint(dcproxy_bp)
    app.register_blueprint(health_bp)
