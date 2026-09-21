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
"""The path Cloud Run probes for liveness.

Deliberately separate from /agent/health, and deliberately trivial: this answers
before the MCP connection or the config fetch has settled, so a slow or
unreachable data plane delays answers rather than failing the startup probe and
putting the service into a crash loop.

Note Cloud Run's frontend reserves /healthz and answers it itself without
forwarding — so this works for the startup probe, which hits the container port
directly, but an external uptime check must target /agent/health instead.
"""

from flask import Blueprint, Response

health_bp = Blueprint("health", __name__)


@health_bp.route("/healthz", methods=["GET"])
def healthz():
    return Response("ok\n", mimetype="text/plain")
