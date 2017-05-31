using Uno;
using Uno.UX;
using Uno.Diagnostics;
using Fuse;
using Fuse.Input;

namespace Fuse.Gestures
{
	delegate void ClickerEventHandler(PointerEventArgs args, int count);

	public abstract class ClickerTrigger : Fuse.Triggers.Trigger
	{
		internal Clicker Clicker;
		protected override void OnRooted()
		{
			base.OnRooted();
			Clicker = Clicker.AttachClicker(Parent);
		}

		protected override void OnUnrooted()
		{
			Clicker.Detach();
			Clicker = null;
			base.OnUnrooted();
		}
	}

	public abstract class WhileClickerTrigger : Fuse.Triggers.WhileTrigger
	{
		internal Clicker Clicker;
		protected override void OnRooted()
		{
			base.OnRooted();
			Clicker = Clicker.AttachClicker(Parent);
		}

		protected override void OnUnrooted()
		{
			Clicker.Detach();
			Clicker = null;
			base.OnUnrooted();
		}
	}

	class Clicker : IGesture
	{
		public event ClickerEventHandler TappedEvent;
		public event ClickerEventHandler ClickedEvent;
		public event ClickerEventHandler LongPressedEvent;
		public event ClickerEventHandler PressingEvent;

		float _maxTapDistanceMoved = 25;
		float _maxTapTimeHeld = 0.3f;
		float _maxDoubleInterval = 0.3f;
		float _longPressTimeout = 0.5f;

		int _attachCount = 1;
		Visual _visual;

		Clicker(Visual visual)
		{
			_visual = visual;
		}

		static readonly PropertyHandle _clickerProperty = Fuse.Properties.CreateHandle();
		static public Clicker AttachClicker(Visual elm)
		{
			object v;
			if (elm.Properties.TryGet(_clickerProperty, out v))
			{
				var c = v as Clicker;
				c._attachCount++;
				return c;
			}

			var nc = new Clicker(elm);
			elm.Properties.Set(_clickerProperty, nc);
			nc.OnRooted();
			return nc;
		}

		public void Detach()
		{
			_attachCount--;
			if (_attachCount == 0)
			{
				OnUnrooted();
				_visual.Properties.Clear(_clickerProperty);
			}
		}

		Gesture _gesture;
		void OnRooted()
		{
			_gesture = Input.Gestures.Add( this, _visual, GestureType.Primary );
		}

		void OnUnrooted()
		{
			_gesture.Dispose();
			_gesture = null;
		}

		float2 _startCoord;

		float2 _pressedPosition;
		internal float2 PressedPosition { get { return _pressedPosition; } }

		double _startTime;

		int _tapCount, _clickCount;
		double _lastUpTime;
		bool _maybeTap;
		bool _hasUpdate;
		bool _hovering;

		PointerEventArgs _lastArgs;

		GestureRequest IGesture.OnPointerPressed(PointerPressedArgs args)
		{
			_lastArgs = args;
			return GestureRequest.Capture;
		}
		
		void IGesture.OnCaptureChanged(PointerEventArgs args, CaptureType how, CaptureType prev)
		{
			var delta = args.Timestamp - _lastUpTime;
			if (delta > _maxDoubleInterval)
			{
				_tapCount = 0;
				_clickCount = 0;
			}

			_pressedPosition = _visual.WindowToLocal(args.WindowPoint);
			_startCoord = args.WindowPoint;
			_startTime = args.Timestamp;
			_maybeTap = true;

			if (LongPressedEvent != null && !_hasUpdate)
			{
				_hasUpdate = true;
				UpdateManager.AddAction(Update);
			}

			if (PressingEvent != null)
				PressingEvent(args, 1);

			_lastArgs = args;
			_hovering = true;
		}

		GestureRequest IGesture.OnPointerMoved(PointerMovedArgs args)
		{
			var distance = Vector.Length(args.WindowPoint - _startCoord);
			var deltaTime = args.Timestamp - _startTime;
			if (distance > _maxTapDistanceMoved || deltaTime > _maxTapTimeHeld)
				_maybeTap = false;

			//give up capture if it can no longer be our gesture
			if (!NeedCapture())
				return GestureRequest.Cancel;

			var hoverNow = _visual.GetHitWindowPoint(args.WindowPoint) != null;
			if (hoverNow != _hovering)
			{
				if (PressingEvent != null)
					PressingEvent(args, hoverNow ? 1 : 0);
				_hovering = hoverNow;
			}

			_lastArgs = args;
			return GestureRequest.Capture;
		}

		bool NeedCapture()
		{
			return (_maybeTap && TappedEvent !=null) ||
				ClickedEvent != null ||
				LongPressedEvent != null ||
				PressingEvent != null;
		}

		GestureRequest IGesture.OnPointerReleased(PointerReleasedArgs args)
		{
			var deltaTime = args.Timestamp - _startTime;
			if (_maybeTap && deltaTime <= _maxTapTimeHeld)
			{
				_tapCount++;
				if (TappedEvent != null)
					TappedEvent(args, _tapCount);
			}
			else
			{
				_tapCount = 0;
			}

			var hoverNow = _visual.GetHitWindowPoint(args.WindowPoint) != null;
			if (hoverNow)
			{
				_clickCount++;
				if (ClickedEvent != null)
					ClickedEvent(args, _clickCount);
			}
			else
			{
				_clickCount = 0;
			}

			if (_hovering && PressingEvent != null)
				PressingEvent(args, 0);
			_hovering = false;

			_lastUpTime = args.Timestamp;
			_lastArgs = args;
			return GestureRequest.Cancel;
		}

		void Update()
		{
			var elapsed = Time.FrameTime - _startTime;
			if (LongPressedEvent != null && elapsed > _longPressTimeout)
			{
				LongPressedEvent(_lastArgs, 0);
				Pointer.ReleaseCapture(this);
				DoneCapture();
			}
		}

		void DoneCapture()
		{
			ReleaseUpdate();

			if (_hovering && PressingEvent != null)
				PressingEvent(_lastArgs, 0);
			_hovering = false;
		}

		void ReleaseUpdate()
		{
			if (_hasUpdate)
			{
				UpdateManager.RemoveAction(Update);
				_hasUpdate = false;
			}
		}

		void IGesture.OnLostCapture(bool forced)
		{
			DoneCapture();
			if (forced)
			{
				_tapCount = 0;
				_clickCount = 0;
			}
		}
		
		GesturePriorityConfig IGesture.Priority
		{
			get
			{
				return new GesturePriorityConfig(
					//As we have no priority we can return a high priority, forcing other gestures to be sure they
					//recognize themselves before stealing from clicker.
					GesturePriority.Highest,
					//0 will prevent it from ever getting a hard capture
					0 );
			}
		}
	}
}
