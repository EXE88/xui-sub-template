from django.db import models


class ClientUsageSnapshot(models.Model):
    subid = models.CharField(max_length=64, db_index=True)
    email = models.CharField(max_length=255, db_index=True)
    used_mb = models.FloatField()
    total_used_bytes = models.BigIntegerField()
    recorded_at = models.DateTimeField(auto_now_add=True, db_index=True)

    class Meta:
        indexes = [
            models.Index(fields=["subid", "recorded_at"]),
            models.Index(fields=["email", "recorded_at"]),
        ]
        ordering = ["recorded_at"]
    
    def __str__(self):
        return f"{self.email} - {self.used_mb} MB at {self.recorded_at}"
