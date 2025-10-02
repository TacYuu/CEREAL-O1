
import requests
from PIL import Image

# Hardcoded credentials for local testing
ROBOFLOW_API_KEY = "LcEWa0FcAevFy6hmciHP"
ROBOFLOW_MODEL = "cereal-hzsdj/2"
SUPABASE_URL = "https://yxbxqvpgoydcnqhtpxxg.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl4YnhxdnBnb3lkY25xaHRweHhnIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1Nzk5NDcxOCwiZXhwIjoyMDczNTcwNzE4fQ.6IW02dZySSzgBmfFiAgN_RjcJi42uyWgMc8tSst04UQ"
LOCAL_IMAGE_PATH = r'C:\Users\Acer\Downloads\test.jpg'  # Use your provided image path

# Roboflow Inference
def test_roboflow(image_path):
    url = f'https://detect.roboflow.com/{ROBOFLOW_MODEL}'
    params = {'api_key': ROBOFLOW_API_KEY}
    with open(image_path, 'rb') as img:
        resp = requests.post(url, params=params, files={'file': img})
    resp.raise_for_status()
    print('Roboflow result:', resp.json())
    return resp.json()


def test_supabase_get(user_id):
    url = f'{SUPABASE_URL}/rest/v1/profiles?id=eq.{user_id}'
    headers = {
        'apikey': SUPABASE_KEY,
        'Authorization': f'Bearer {SUPABASE_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
    }
    resp = requests.get(url, headers=headers)
    resp.raise_for_status()
    print('Supabase GET result:', resp.json())
    return resp.json()

def test_supabase_insert(points, user_id):
    url = f'{SUPABASE_URL}/rest/v1/profiles?id=eq.{user_id}'
    headers = {
        'apikey': SUPABASE_KEY,
        'Authorization': f'Bearer {SUPABASE_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation'
    }
    data = {"points": points}
    resp = requests.patch(url, headers=headers, json=data)
    resp.raise_for_status()
    print('Supabase update result:', resp.json())
    return resp.json()

if __name__ == '__main__':
    print('ROBOFLOW_MODEL:', ROBOFLOW_MODEL)
    print('ROBOFLOW_API_KEY:', ROBOFLOW_API_KEY)
    print('SUPABASE_URL:', SUPABASE_URL)
    print('SUPABASE_KEY:', SUPABASE_KEY)
    # Test Roboflow
    result = test_roboflow(LOCAL_IMAGE_PATH)
    # Test Supabase: GET profile with given UUID
    test_supabase_get(user_id="1cf44741-bc4b-49bd-be9a-14a5ac31331a")
    # Test Supabase: add points to profile with given UUID
    test_supabase_insert(points=5, user_id="1cf44741-bc4b-49bd-be9a-14a5ac31331a")
