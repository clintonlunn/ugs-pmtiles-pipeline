# Deployment Options

Two ways to run this pipeline:
1. **Local/Laptop** - Run manually or via cron
2. **Cloud Run Job** - Scheduled serverless execution

## Option 1: Local Execution (FREE)

### Setup

```bash
# Install dependencies (one-time)
# macOS:
brew install gdal jq
brew install tippecanoe

# Ubuntu/Debian:
sudo apt-get install gdal-bin jq
# Install tippecanoe from source (see README)

# Install gcloud for uploads
# https://cloud.google.com/sdk/docs/install
```

### Run Conversion

```bash
# Single layer
./scripts/convert-layer.sh hazards:quaternaryfaults_current

# All enabled layers
./scripts/convert-all.sh

# Upload to GCS manually
gsutil -m cp output/*.pmtiles gs://ugs-pmtiles/
```

### Scheduled Execution (Cron)

```bash
# Add to crontab for weekly runs (Sunday 2am)
0 2 * * 0 cd /path/to/ugs-pmtiles-pipeline && ./scripts/convert-all.sh && gsutil -m cp output/*.pmtiles gs://ugs-pmtiles/
```

**Cost: $0** (uses your laptop/workstation)

---

## Option 2: Cloud Run Job (Automated)

### Cost Estimate

**Cloud Run Jobs Pricing:**
- vCPU: $0.00002400/vCPU-second
- Memory: $0.00000250/GiB-second
- Free tier: 180,000 vCPU-seconds/month

**Estimated per run:**
- 36 layers × 2 minutes avg = 72 minutes = 4,320 seconds
- 1 vCPU, 2 GiB memory
- Cost per run: 4,320 × ($0.000024 + 2×$0.0000025) = **$0.13/run**

**Monthly cost (weekly runs):**
- 4 runs/month × $0.13 = **$0.52/month**
- **Free tier covers ~700 layers/month** (well above your needs)

**Likely cost: $0/month** (within free tier)

### Setup

1. **Build and push container:**

```bash
# Set your GCP project
export PROJECT_ID=your-gcp-project
export REGION=us-central1

# Build container
gcloud builds submit --tag gcr.io/$PROJECT_ID/ugs-pmtiles-pipeline

# Or use Artifact Registry
docker build -t us-docker.pkg.dev/$PROJECT_ID/ugs/pmtiles-pipeline .
docker push us-docker.pkg.dev/$PROJECT_ID/ugs/pmtiles-pipeline
```

2. **Create GCS bucket:**

```bash
gsutil mb -l $REGION gs://ugs-pmtiles
```

3. **Deploy Cloud Run Job:**

```bash
gcloud run jobs create ugs-pmtiles-converter \
  --image gcr.io/$PROJECT_ID/ugs-pmtiles-pipeline \
  --region $REGION \
  --memory 2Gi \
  --cpu 1 \
  --max-retries 1 \
  --task-timeout 3600 \
  --set-env-vars GCS_BUCKET=gs://ugs-pmtiles
```

4. **Run manually:**

```bash
gcloud run jobs execute ugs-pmtiles-converter --region $REGION
```

5. **Schedule via Cloud Scheduler:**

```bash
# Weekly on Sundays at 2am
gcloud scheduler jobs create http ugs-pmtiles-weekly \
  --location $REGION \
  --schedule="0 2 * * 0" \
  --uri="https://$REGION-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/$PROJECT_ID/jobs/ugs-pmtiles-converter:run" \
  --http-method POST \
  --oauth-service-account-email PROJECT_NUMBER-compute@developer.gserviceaccount.com
```

---

## Recommendation

### Start with Local:
- Free
- Simple to test
- You control when it runs
- Good for initial testing

### Move to Cloud Run when:
- You want automated weekly/nightly runs
- Team needs access without your laptop
- Want to run from PostGIS (faster network within GCP)
- Cost is negligible (~$0/month with free tier)

---

## Switching Data Source (WFS → PostGIS)

When you get PostGIS credentials:

1. **Update `config/datasource.json`:**

```json
{
  "type": "postgis",
  "postgis": {
    "host": "your-cloudsql-instance",
    "port": 5432,
    "database": "ugs_gis",
    "user": "readonly_user",
    "password": "${PGPASSWORD}",
    "enabled": true
  }
}
```

2. **Set password as environment variable:**

```bash
# Local
export PGPASSWORD=your_password

# Cloud Run
gcloud run jobs update ugs-pmtiles-converter \
  --set-secrets PGPASSWORD=ugs-postgres-password:latest
```

3. **Update layer configs** with correct table names in `config/layers.json`

**That's it!** No code changes needed.

---

## Performance Comparison

| Method | Speed (36 layers) | Cost/month | Setup |
|--------|------------------|------------|-------|
| Local (laptop) | 1-2 hours | $0 | Easy |
| Cloud Run (WFS) | 1-2 hours | $0 (free tier) | Moderate |
| Cloud Run (PostGIS) | 10-20 min | $0 (free tier) | Easy (after creds) |

**PostGIS is 3-6x faster** than WFS due to direct connection.
