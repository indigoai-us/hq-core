# add-monitoring

Add monitoring and observability to application.

## Arguments

`$ARGUMENTS` = `--repo <path>` (required)

Optional:
- `--type <metrics|logs|traces|all>` - Monitoring type
- `--provider <datadog|newrelic|prometheus|otel>` - Monitoring provider
- `--alerts` - Include alerting rules

## Codex Execution

```bash
cd {repo} && codex exec --full-auto -c model="gpt-5.4" --reasoning high --fast --cd {repo} \
  "Add {monitoring_type} monitoring using {provider}. Include health checks, structured logging, and key metrics instrumentation." 2>&1
```

## Process

1. Analyze application architecture
2. Identify key metrics:
   - Request latency
   - Error rates
   - Resource usage
   - Business metrics
3. Design instrumentation:
   - HTTP middleware
   - Database queries
   - External API calls
4. Configure logging:
   - Structured JSON logs
   - Log levels
   - Correlation IDs
5. Add health checks:
   - Liveness probe
   - Readiness probe
6. Create alerting rules (if --alerts)
7. Present for human approval

## Output

- Instrumentation code
- Health check endpoints
- Alert configuration
- Dashboard templates (if available)

## OpenTelemetry Setup

```typescript
import { NodeSDK } from '@opentelemetry/sdk-node';
import { getNodeAutoInstrumentations } from '@opentelemetry/auto-instrumentations-node';

const sdk = new NodeSDK({
  serviceName: 'my-service',
  instrumentations: [getNodeAutoInstrumentations()],
});

sdk.start();
```

## Health Check Pattern

```typescript
app.get('/health/live', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/health/ready', async (req, res) => {
  const dbOk = await checkDatabase();
  const cacheOk = await checkCache();
  if (dbOk && cacheOk) {
    res.json({ status: 'ready' });
  } else {
    res.status(503).json({ status: 'not ready' });
  }
});
```
