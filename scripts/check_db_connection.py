import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app import create_app
from app.models import Complaint


app = create_app()

with app.app_context():
    complaints = (
        Complaint.query
        .order_by(Complaint.created_at.desc())
        .limit(5)
        .all()
    )

    print(f"Connected. Found {len(complaints)} complaint(s):")

    for c in complaints:
        print(
            f"  id={c.id} "
            f"complaint_id={c.complaint_id} "
            f"status={c.status} "
            f"lat={c.latitude} "
            f"lng={c.longitude} "
            f"created_at={c.created_at}"
        )